import CoreGraphics
import CoreImage
import Foundation
import Metal

/// The render pipeline. The whole graph is Core Image nodes, rebuilt fresh
/// per frame; Core Image fuses it and computes only the region of interest, so
/// no intermediate rasters are cached.
///
/// Per visible layer, bottom-up:
///   1. source as CIImage (tagged with its own profile; CI converts to the
///      linear P3 working space in float)
///   2. layer.transform — via Lanczos when the downscale exceeds ~50%,
///      plain affine (bilinear) otherwise
///   3. opacity multiplies premultiplied RGBA
///   4. mask applied with CIBlendWithMask: background = accumulated composite,
///      foreground = this layer over the accumulator, mask transformed into
///      canvas space by the same matrix. (Using layer-over-accumulator as the
///      foreground makes the blend algebraically identical to multiplying the
///      layer's alpha by the mask — Photoshop's semantics for layers that have
///      their own transparency. That equivalence holds because source-over is
///      affine in the layer's alpha within the compositing space; non-normal
///      blend modes break it, so they apply the mask in the direct
///      alpha-multiplication form instead — see `layerComposited`.)
///   5. blend onto the accumulator: source-over for `.normal` (linear light,
///, bit-identical to the pre-blend-mode pipeline); other modes run
///      their Core Image blend filter inside a gamma sandwich for Photoshop
///      parity — see `blended(_:over:mode:)`.
///
/// Clipping masks: a run of consecutive
/// `isClippedToBelow` layers renders as one group with the unclipped layer
/// below it — see `compositeImage` and `clippedGroupComposited`.
final class RenderEngine {
    static let shared = RenderEngine()

    let device: MTLDevice?
    let context: CIContext

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
        let options: [CIContextOption: Any] = [
            // Composite in linear light, not gamma-encoded — set explicitly.
            .workingColorSpace: DezzyColorSpace.linearWorking,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: true,
            .name: "DezzyRender",
        ]
        if let device {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    // MARK: - CIImage caches
    // CIImage wrappers are cheap, but caching them keyed on the immutable
    // source/mask storage lets Core Image reuse its GPU texture uploads across
    // frames. Pruned against the current document on structural changes.

    private let cacheLock = NSLock()
    private var sourceCache: [ObjectIdentifier: CIImage] = [:]
    private var maskCache: [UUID: CIImage] = [:]

    /// Keyed on the CGImage's address, unlike the mask cache below — safe
    /// here only because the cached `CIImage` retains the `CGImage`, so a key
    /// cannot be recycled while an entry holds it. The mask cache stores no
    /// such reference, which is why it keys on a UUID instead.
    func ciImage(forSource source: CGImage) -> CIImage {
        let key = ObjectIdentifier(source)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = sourceCache[key] { return cached }
        let image = CIImage(cgImage: source)
        sourceCache[key] = image
        return image
    }

    /// Mask samples are coverage values, not colours — colorSpace nil keeps
    /// Core Image from colour-matching them.
    func ciImage(forMask texture: MaskTexture) -> CIImage {
        let key = texture.storageIdentity
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached = maskCache[key] { return cached }
        let image = CIImage(bitmapData: texture.data,
                            bytesPerRow: texture.width,
                            size: CGSize(width: texture.width, height: texture.height),
                            format: .L8,
                            colorSpace: nil)
        maskCache[key] = image
        return image
    }

    func pruneCaches(for document: Document) {
        var sourceKeys = Set<ObjectIdentifier>()
        var maskKeys = Set<UUID>()
        for layer in document.layers {
            sourceKeys.insert(ObjectIdentifier(layer.source))
            if let mask = layer.mask { maskKeys.insert(mask.texture.storageIdentity) }
        }
        cacheLock.lock(); defer { cacheLock.unlock() }
        sourceCache = sourceCache.filter { sourceKeys.contains($0.key) }
        maskCache = maskCache.filter { maskKeys.contains($0.key) }
    }

    // MARK: - Graph construction

    /// Applies an affine transform with appropriate resampling: for downscales
    /// beyond ~50% the scale part runs through Lanczos (plain affine aliases
    /// badly there), then the scale-free remainder (rotation/translation/flip)
    /// is applied as a plain affine.
    static func resampled(_ image: CIImage, by transform: CGAffineTransform) -> CIImage {
        let (sx, sy) = transform.scaleComponents
        guard sx.isFinite, sy.isFinite, min(sx, sy) > 1e-4 else { return .empty() }
        guard min(sx, sy) < 0.5 else { return image.transformed(by: transform) }

        guard let lanczos = CIFilter(name: "CILanczosScaleTransform") else {
            return image.transformed(by: transform)
        }
        lanczos.setValue(image, forKey: kCIInputImageKey)
        lanczos.setValue(sy, forKey: kCIInputScaleKey)
        lanczos.setValue(sx / sy, forKey: kCIInputAspectRatioKey)
        guard let scaled = lanczos.outputImage else { return image.transformed(by: transform) }
        // Residual R with R∘S == transform (S = the pure scale Lanczos applied).
        let residual = CGAffineTransform(scaleX: 1 / sx, y: 1 / sy).concatenating(transform)
        return scaled.transformed(by: residual)
    }

    /// Multiplies the layer's alpha by `opacity` via CIColorMatrix.
    /// CIColorMatrix operates on unpremultiplied components, so only the alpha
    /// vector scales — touching RGB as well would apply opacity twice.
    static func withOpacity(_ image: CIImage, _ opacity: Float) -> CIImage {
        guard opacity < 1 else { return image }
        let o = CGFloat(max(0, opacity))
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: o), forKey: "inputAVector")
        return filter.outputImage ?? image
    }

    // MARK: - Blend modes

    /// Blends `image` onto `background` using `mode`.
    ///
    /// Colour-space reconciliation (parity vs linear compositing):
    /// Photoshop applies blend-mode arithmetic to gamma-encoded
    /// document-space values by default ("Blend RGB Colors Using Gamma 1.0"
    /// is off), while this pipeline composites in linear light. Running
    /// the CI blend filters directly in the linear working space would
    /// visibly diverge from Photoshop — Screen of two mid-greys gives 191
    /// encoded (Photoshop) vs ~166 via linear-space math. Since the success
    /// criterion is Photoshop-indistinguishability, non-normal modes run
    /// inside a gamma "sandwich": encode with the sRGB transfer function
    /// (Display P3's curve, i.e. the document space's encoding) → CI blend
    /// filter → decode back to linear. Straight-alpha handling matters —
    /// encode(α·C) ≠ α·encode(C) — and the tone-curve filters provide it
    /// themselves: CILinearToSRGBToneCurve / CISRGBToneCurveToLinear
    /// unpremultiply their input, apply the curve to straight RGB, and
    /// re-premultiply (verified empirically; adding explicit
    /// un/premultiplies around them double-corrects and skews partial-alpha
    /// pixels). The blend filters then implement the premultiplied PDF
    /// compositing equations on the encoded values, which reproduces
    /// Photoshop's straight-alpha encoded-space math exactly (verified
    /// analytically in BlendClippingTests, including at partial opacity).
    ///
    /// `.normal` never enters the sandwich — it stays on the source-over
    /// fast path in linear light, byte-identical to the pre-blend-mode
    /// pipeline (the golden references pin it). Opacity and masks also keep
    /// their established linear-light semantics for every mode; only the
    /// layer-meets-accumulator arithmetic is encoded.
    static func blended(_ image: CIImage, over background: CIImage,
                        mode: BlendMode) -> CIImage {
        guard let filterName = mode.ciFilterName,
              let filter = CIFilter(name: filterName) else {
            return image.composited(over: background)
        }
        filter.setValue(Self.gammaEncoded(image), forKey: kCIInputImageKey)
        filter.setValue(Self.gammaEncoded(background), forKey: kCIInputBackgroundImageKey)
        guard let blendedEncoded = filter.outputImage else {
            return image.composited(over: background)
        }
        return Self.gammaDecoded(blendedEncoded)
    }

    /// Linear working-space values → gamma-encoded document-space values.
    /// The filter applies the curve to straight (unpremultiplied) RGB
    /// internally — see `blended`.
    private static func gammaEncoded(_ image: CIImage) -> CIImage {
        image.applyingFilter("CILinearToSRGBToneCurve")
    }

    /// Inverse of `gammaEncoded`. Internal because the gradient-overlay
    /// effect ramps in encoded space too (Photoshop interpolates gradient
    /// stops on document values, not in linear light) and decodes with this.
    static func gammaDecoded(_ image: CIImage) -> CIImage {
        image.applyingFilter("CISRGBToneCurveToLinear")
    }

    /// image × mask: multiplies the premultiplied layer by the mask's
    /// coverage (transparent where the mask is black), cropped to `extent`.
    /// This is the direct alpha-multiplication form of mask application —
    /// same semantics as the lerp form documented in the header, needed
    /// where the result cannot be formed by interpolating against the
    /// accumulator (non-normal blends, clipped groups).
    static func alphaMasked(_ image: CIImage, by mask: CIImage,
                            within extent: CGRect) -> CIImage {
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            return image.cropped(to: extent)
        }
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: extent),
                       forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return (blend.outputImage ?? image).cropped(to: extent)
    }

    /// The image's colour with alpha forced fully opaque (unpremultiplied
    /// RGB preserved — CIColorMatrix operates on unpremultiplied
    /// components). Zero-alpha regions have no defined colour and come out
    /// black; the alpha bias makes the output extent infinite. Callers must
    /// therefore confine the result to the source's coverage — the clipped
    /// group does exactly that.
    static func opaqueColor(of image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }

    /// The image's straight alpha as an opaque grayscale (R=G=B=α, A=1),
    /// usable as a CIBlendWithMask mask. Outside the image's extent the
    /// coverage is 0.
    static func alphaCoverage(of image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        let alpha = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(alpha, forKey: "inputRVector")
        filter.setValue(alpha, forKey: "inputGVector")
        filter.setValue(alpha, forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }

    // MARK: - Per-layer compositing

    /// Shared per-layer graph prep: the source (with any live stroke)
    /// resampled by transform ∘ outputTransform with opacity applied, plus
    /// the enabled mask resampled into the same space (nil when absent or
    /// disabled).
    /// `applyingOpacity: false` returns the layer's shape at full strength —
    /// what the effects pipeline generates from, since Photoshop's layer
    /// opacity scales the finished style rather than the shape it is built
    /// from.
    private func preparedLayer(_ layer: Layer, outputTransform: CGAffineTransform,
                               stroke: StrokePreview?,
                               applyingOpacity: Bool = true) -> (image: CIImage, maskInCanvas: CIImage?) {
        let effective = layer.transform.concatenating(outputTransform)
        var sourceCI = ciImage(forSource: layer.source)
        var maskCI = layer.mask.map { ciImage(forMask: $0.texture) }

        if let stroke, stroke.layerID == layer.id {
            if stroke.targetsMask, let baseMask = maskCI {
                maskCI = Self.strokeAppliedToMask(baseMask, stroke: stroke,
                                                  bounds: layer.sourceRect)
            } else if !stroke.targetsMask {
                sourceCI = Self.strokeAppliedToPaint(sourceCI, stroke: stroke,
                                                     bounds: layer.sourceRect)
            }
        }

        var image = Self.resampled(sourceCI, by: effective)
        if applyingOpacity { image = Self.withOpacity(image, layer.opacity) }
        guard let maskCI, layer.mask?.isEnabled == true else { return (image, nil) }
        return (image, Self.resampled(maskCI, by: effective))
    }

    /// The layer's own contribution — source × opacity × enabled mask — as
    /// one premultiplied image over transparency (mask applied in
    /// alpha-multiplication form). Used by the clipped-group builder, where
    /// members blend against the group, not the accumulator.
    func layerImage(_ layer: Layer, outputTransform: CGAffineTransform,
                    stroke: StrokePreview? = nil) -> CIImage {
        if layer.effects.isActive {
            return effectsComposited(layer, over: .empty(), outputTransform: outputTransform,
                                     stroke: stroke)
        }
        return unstyledLayerImage(layer, outputTransform: outputTransform, stroke: stroke)
    }

    /// The layer's contribution with its effects ignored — the pre-effects
    /// `layerImage`. The clipped-group builder needs it for the confinement
    /// mask (clipped members clip to the base's FILL, not to its shadow).
    private func unstyledLayerImage(_ layer: Layer, outputTransform: CGAffineTransform,
                                    stroke: StrokePreview?) -> CIImage {
        let (image, maskInCanvas) = preparedLayer(layer, outputTransform: outputTransform,
                                                  stroke: stroke)
        guard let maskInCanvas else { return image }
        return Self.alphaMasked(image, by: maskInCanvas, within: image.extent)
    }

    // MARK: - Layer effects

    /// The layer's shape at full strength — source × enabled mask, no opacity
    /// — which is what `LayerEffectRenderer` builds its mattes from.
    private func effectContent(_ layer: Layer, outputTransform: CGAffineTransform,
                               stroke: StrokePreview?) -> CIImage {
        let (image, maskInCanvas) = preparedLayer(layer, outputTransform: outputTransform,
                                                  stroke: stroke, applyingOpacity: false)
        guard let maskInCanvas else { return image }
        return Self.alphaMasked(image, by: maskInCanvas, within: image.extent)
    }

    /// Canvas points → output pixels. Effect sizes are canvas-space ('s
    /// space), so they scale with zoom exactly as the layer's pixels do. The
    /// output transform is scale + translation only (viewport or identity),
    /// so one uniform factor is enough.
    static func effectScale(_ outputTransform: CGAffineTransform) -> CGFloat {
        let (sx, sy) = outputTransform.scaleComponents
        let scale = (abs(sx) + abs(sy)) / 2
        return scale.isFinite && scale > 0 ? scale : 1
    }

    /// A styled layer over `accumulated`: exterior effects (drop shadow,
    /// outer glow) blend onto the backdrop with their OWN modes first — that
    /// is Photoshop's model and the reason they can't just be baked into the
    /// layer image — then the fill with its interior effects blends with the
    /// LAYER's mode. Layer opacity scales all of it, effects included.
    private func effectsComposited(_ layer: Layer, over accumulated: CIImage,
                                   outputTransform: CGAffineTransform,
                                   stroke: StrokePreview?) -> CIImage {
        let content = effectContent(layer, outputTransform: outputTransform, stroke: stroke)
        let scale = Self.effectScale(outputTransform)
        var result = accumulated
        for pass in LayerEffectRenderer.exteriorPasses(layer.effects, content: content,
                                                       scale: scale) {
            let image = Self.withOpacity(pass.image, Float(pass.opacity) * layer.opacity)
            result = Self.blended(image, over: result, mode: pass.mode)
        }
        let styled = LayerEffectRenderer.styledFill(layer.effects, content: content, scale: scale)
        return Self.blended(Self.withOpacity(styled, layer.opacity), over: result,
                            mode: layer.blendMode)
    }

    /// `outputTransform` maps canvas space to the output raster (identity for
    /// export; the view transform for display). It is folded into each layer's
    /// transform before resampling, so a zoomed-out canvas costs only
    /// viewport-resolution work per layer — and a heavily downscaled layer gets
    /// a single Lanczos pass at its total effective scale.
    /// `stroke` is an in-progress brush stroke previewed live on its target.
    func layerComposited(_ layer: Layer, over accumulated: CIImage,
                         outputTransform: CGAffineTransform,
                         stroke: StrokePreview? = nil) -> CIImage {
        if layer.effects.isActive {
            return effectsComposited(layer, over: accumulated, outputTransform: outputTransform,
                                     stroke: stroke)
        }
        let (image, maskInCanvas) = preparedLayer(layer, outputTransform: outputTransform,
                                                  stroke: stroke)
        if layer.blendMode == .normal {
            // fast path — graph-identical to the pre-blend-mode pipeline.
            guard let maskInCanvas else {
                return image.composited(over: accumulated)
            }
            let layerOverAccumulated = image.composited(over: accumulated)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { return layerOverAccumulated }
            blend.setValue(layerOverAccumulated, forKey: kCIInputImageKey)
            blend.setValue(accumulated, forKey: kCIInputBackgroundImageKey)
            blend.setValue(maskInCanvas, forKey: kCIInputMaskImageKey)
            return blend.outputImage ?? layerOverAccumulated
        }
        // Non-normal modes: the lerp-form mask application is only exact when
        // the blended result is affine in the layer's alpha within the
        // compositing space — true for source-over in linear light, false
        // across the gamma sandwich. Apply the mask to the layer's alpha
        // first, then blend (identical semantics, different factoring).
        var masked = image
        if let maskInCanvas {
            masked = Self.alphaMasked(image, by: maskInCanvas, within: image.extent)
        }
        return Self.blended(masked, over: accumulated, mode: layer.blendMode)
    }

    /// A clipping group (Photoshop semantics): `clipped`
    /// holds the visible clipped layers stacked directly above `base`,
    /// bottom-first.
    ///
    /// Algebra — accumulate, then intersect:
    ///   1. backdrop = the base's colour made opaque. Its alpha pattern is
    ///      reapplied in step 3, so it must not weight the group twice; where
    ///      the base has zero alpha the colour is undefined (black) and is
    ///      stamped out by step 3 anyway.
    ///   2. group = each clipped layer blended over the backdrop with its own
    ///      blend mode, opacity and mask. Members blend against the base's
    ///      CONTENT, not the accumulator — a Multiply clip darkens its base,
    ///      never the layers beneath the group.
    ///   3. confined = group × base alpha (source alpha × opacity × mask):
    ///      the group inherits the base's transparency exactly. The base's
    ///      opacity scales the finished group once (Photoshop's "blend
    ///      clipped layers as group" default), clipped content past the
    ///      base's edge vanishes, and a feathered base edge fades the whole
    ///      group with it. With no clipped members this reduces
    ///      algebraically to the base image itself.
    ///   4. the confined group blends onto the accumulator with the BASE's
    ///      blend mode, exactly as the base alone would.
    /// Layer effects on the base follow Photoshop's rule that the base's
    /// blending options apply to the whole clipping group: its exterior
    /// effects land on the backdrop behind the group, and its interior
    /// effects colour the backdrop the members blend against. The confinement
    /// mask stays the base's FILL alpha, so a clipped member is bounded by
    /// the base's pixels and not by its shadow. One consequence to know: an
    /// outside stroke on a clipping-group base is confined away with
    /// everything else outside the fill.
    func clippedGroupComposited(base: Layer, clipped: [Layer], over accumulated: CIImage,
                                outputTransform: CGAffineTransform,
                                stroke: StrokePreview? = nil) -> CIImage {
        let baseImage = unstyledLayerImage(base, outputTransform: outputTransform, stroke: stroke)
        var backdrop = accumulated
        var baseFill = baseImage
        if base.effects.isActive {
            let content = effectContent(base, outputTransform: outputTransform, stroke: stroke)
            let scale = Self.effectScale(outputTransform)
            for pass in LayerEffectRenderer.exteriorPasses(base.effects, content: content,
                                                           scale: scale) {
                let image = Self.withOpacity(pass.image, Float(pass.opacity) * base.opacity)
                backdrop = Self.blended(image, over: backdrop, mode: pass.mode)
            }
            // Only the colour matters here — `opaqueColor` discards alpha and
            // the base's opacity is reapplied by the confinement below.
            baseFill = LayerEffectRenderer.styledFill(base.effects, content: content, scale: scale)
        }
        var group = Self.opaqueColor(of: baseFill)
        for layer in clipped {
            let image = layerImage(layer, outputTransform: outputTransform, stroke: stroke)
            group = Self.blended(image, over: group, mode: layer.blendMode)
        }
        let confined = Self.alphaMasked(group, by: Self.alphaCoverage(of: baseImage),
                                        within: baseImage.extent)
        return Self.blended(confined, over: backdrop, mode: base.blendMode)
    }

    /// The full document composite, cropped to the canvas frame (both in the
    /// output space defined by `outputTransform`). `excludingLayer` hides one
    /// layer without touching the document — used while its live text-editing
    /// overlay replaces it on screen.
    ///
    /// Clipping groups: a run of consecutive `isClippedToBelow` layers
    /// belongs to the nearest unclipped layer below it (its base) and renders
    /// through `clippedGroupComposited`. A hidden (or text-excluded) base
    /// hides its whole group, Photoshop-style; a hidden clipped member is
    /// skipped without breaking the run; a clipped layer with no valid base —
    /// bottom of the stack, or first in its group scope — renders unclipped,
    /// matching the model's `normalizingClipping()` rule.
    ///
    /// Layer groups: the stack composites through
    /// `Document.stackNodes()`. A PASS-THROUGH group (no explicit blend mode,
    /// full opacity) recurses onto the SAME accumulator — for such groups the
    /// graph is node-for-node identical to the ungrouped stack, so grouping
    /// alone never changes a pixel (fast path preserved). An ISOLATED
    /// group (mode set, or opacity < 100%) renders its members over
    /// transparency, scales by the group's opacity, and composites once with
    /// the group's mode. Clip runs live inside one node list, so a group
    /// boundary breaks them structurally. A hidden group prunes its whole
    /// subtree (effective visibility).
    func compositeImage(for document: Document,
                        outputTransform: CGAffineTransform = .identity,
                        stroke: StrokePreview? = nil,
                        excludingLayer: UUID? = nil) -> CIImage {
        let accumulated = composited(document.stackNodes(), over: .empty(),
                                     outputTransform: outputTransform,
                                     stroke: stroke, excludingLayer: excludingLayer)
        return accumulated.cropped(to: document.canvasRect.applying(outputTransform))
    }

    /// Composites one node list (a group's direct children, or the document
    /// root), bottom-first, over `background`. This is the pre-group flat
    /// loop generalised to a list containing folder nodes.
    private func composited(_ nodes: [StackNode], over background: CIImage,
                            outputTransform: CGAffineTransform,
                            stroke: StrokePreview?, excludingLayer: UUID?) -> CIImage {
        var accumulated = background
        var index = 0
        while index < nodes.count {
            if case .group(let group, let children) = nodes[index] {
                index += 1
                guard group.isVisible else { continue }
                if group.isIsolated {
                    var flattened = composited(children, over: .empty(),
                                               outputTransform: outputTransform,
                                               stroke: stroke, excludingLayer: excludingLayer)
                    flattened = Self.withOpacity(flattened, group.opacity)
                    accumulated = Self.blended(flattened, over: accumulated,
                                               mode: group.blendMode ?? .normal)
                } else {
                    accumulated = composited(children, over: accumulated,
                                             outputTransform: outputTransform,
                                             stroke: stroke, excludingLayer: excludingLayer)
                }
                continue
            }
            guard case .layer(let base) = nodes[index] else { index += 1; continue }
            var next = index + 1
            var clipped: [Layer] = []
            while next < nodes.count, case .layer(let member) = nodes[next],
                  member.isClippedToBelow {
                if member.isVisible && member.id != excludingLayer { clipped.append(member) }
                next += 1
            }
            if base.isVisible && base.id != excludingLayer {
                if clipped.isEmpty {
                    accumulated = layerComposited(base, over: accumulated,
                                                  outputTransform: outputTransform, stroke: stroke)
                } else {
                    accumulated = clippedGroupComposited(base: base, clipped: clipped,
                                                         over: accumulated,
                                                         outputTransform: outputTransform,
                                                         stroke: stroke)
                }
            }
            index = next
        }
        return accumulated
    }

    // MARK: - Brush stroke preview & bake
    // Preview and bake share these graph builders, so what you see while
    // dragging is exactly what commits.

    /// Coverage as a raw (un-colour-managed) CIImage placed in target space.
    private static func strokeCoverageCI(_ stroke: StrokePreview) -> CIImage {
        CIImage(cgImage: stroke.coverageImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: stroke.originYUp.x,
                                               y: stroke.originYUp.y))
    }

    /// mask' = mask·(1−c) + value·c, all in raw mask-value space.
    static func strokeAppliedToMask(_ mask: CIImage, stroke: StrokePreview,
                                    bounds: CGRect) -> CIImage {
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return mask }
        var value = Data(count: 1)
        value[0] = stroke.maskValue
        let gray = CIImage(bitmapData: value, bytesPerRow: 1,
                           size: CGSize(width: 1, height: 1),
                           format: .L8, colorSpace: nil)
            .clampedToExtent()
            .cropped(to: bounds)
        blend.setValue(gray, forKey: kCIInputImageKey)
        blend.setValue(mask, forKey: kCIInputBackgroundImageKey)
        blend.setValue(strokeCoverageCI(stroke), forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? mask
    }

    /// Brush: source' = colour·c + source·(1−c). Eraser: source' = source·(1−c).
    static func strokeAppliedToPaint(_ source: CIImage, stroke: StrokePreview,
                                     bounds: CGRect) -> CIImage {
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return source }
        let foreground: CIImage
        if let color = stroke.paintColor, let ciColor = CIColor(cgColor: color) as CIColor? {
            foreground = CIImage(color: ciColor).cropped(to: bounds)
        } else {
            foreground = CIImage(color: .clear).cropped(to: bounds)
        }
        blend.setValue(foreground, forKey: kCIInputImageKey)
        blend.setValue(source, forKey: kCIInputBackgroundImageKey)
        blend.setValue(strokeCoverageCI(stroke), forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? source
    }

    /// Bakes a finished mask stroke into a texture (one COW copy, one render).
    func bakeMaskStroke(into texture: MaskTexture, stroke: StrokePreview) -> MaskTexture {
        let bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let blended = Self.strokeAppliedToMask(ciImage(forMask: texture),
                                               stroke: stroke, bounds: bounds)
        var result = texture
        result.mutate { data in
            data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                self.context.render(blended, toBitmap: base,
                                    rowBytes: texture.width, bounds: bounds,
                                    format: .L8, colorSpace: nil)
            }
        }
        return result
    }

    /// Bakes a finished paint-layer stroke into a new immutable source image.
    func bakePaintStroke(into source: CGImage, stroke: StrokePreview) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let blended = Self.strokeAppliedToPaint(ciImage(forSource: source),
                                                stroke: stroke, bounds: bounds)
        return context.createCGImage(blended, from: bounds, format: .RGBA8,
                                     colorSpace: source.colorSpace ?? DezzyColorSpace.displayP3)
    }

    // MARK: - Display

    struct DisplayStyle {
        var surroundColor = CIColor(red: 0.145, green: 0.145, blue: 0.145,
                                    alpha: 1, colorSpace: DezzyColorSpace.sRGB)!
        var checkerColorA = CIColor(red: 0.78, green: 0.78, blue: 0.78,
                                    alpha: 1, colorSpace: DezzyColorSpace.sRGB)!
        var checkerColorB = CIColor(red: 0.62, green: 0.62, blue: 0.62,
                                    alpha: 1, colorSpace: DezzyColorSpace.sRGB)!
        var checkerSquare: CGFloat = 8
    }

    /// Canvas composite placed under the view transform (canvas→view pixels),
    /// over a transparency checkerboard and a neutral surround filling the
    /// view.
    ///
    /// Magnified (more than one device pixel per document pixel), the
    /// composite is built at canvas resolution and enlarged nearest-neighbour,
    /// so document pixels show as hard-edged squares like Photoshop's rather
    /// than a smooth blur. Minified it renders straight into view space as
    /// before (§3 budget: the fit-zoom path is unchanged).
    ///
    /// The checkerboard keeps a fixed screen size at every zoom, like
    /// Photoshop's, but is anchored to the canvas's top-left corner so it
    /// scrolls with the image.
    ///
    /// The requested transform is first snapped so the canvas edges fall on
    /// whole device pixels (`DisplayGeometry.pixelAligned`) — the overlay's
    /// pixel grid snaps the same way.
    func displayImage(for document: Document,
                      viewTransform requestedTransform: CGAffineTransform,
                      viewPixelBounds: CGRect,
                      contentScale: CGFloat,
                      stroke: StrokePreview? = nil,
                      excludingLayer: UUID? = nil,
                      style: DisplayStyle = DisplayStyle()) -> CIImage {
        let viewTransform = DisplayGeometry.pixelAligned(requestedTransform,
                                                         canvasSize: document.canvasSize)
        let canvasScreenRect = document.canvasRect.applying(viewTransform)
        let (sx, sy) = viewTransform.scaleComponents
        let composite: CIImage
        var checkerRect = canvasScreenRect
        if min(sx, sy) > 1, viewTransform.isInvertible {
            // Only the visible canvas region (plus a pixel of sampler slack)
            // is built; CI pulls just that ROI.
            let visibleCanvas = viewPixelBounds.applying(viewTransform.inverted())
                .insetBy(dx: -1, dy: -1).integral
                .intersection(document.canvasRect)
            // Clamped, so every device pixel inside the whole-pixel canvas
            // rect samples real canvas content, never what lies past its edge.
            composite = visibleCanvas.isNull ? .empty()
                : compositeImage(for: document, outputTransform: .identity,
                                 stroke: stroke, excludingLayer: excludingLayer)
                    .cropped(to: visibleCanvas)
                    .clampedToExtent()
                    .samplingNearest()
                    .transformed(by: viewTransform)
                    .cropped(to: canvasScreenRect)
        } else {
            composite = compositeImage(for: document, outputTransform: viewTransform,
                                       stroke: stroke, excludingLayer: excludingLayer)
            // Resampling below 100% pulls a little of whatever lies just past
            // the canvas edge (usually transparency) into the outermost device
            // pixel. Ending the checkerboard one device pixel short lets that
            // soft edge fade into the surround instead of flashing the checker.
            checkerRect = canvasScreenRect.insetBy(dx: 1, dy: 1)
        }

        var checker = CIImage.empty()
        if let generator = CIFilter(name: "CICheckerboardGenerator") {
            generator.setValue(CIVector(x: canvasScreenRect.minX, y: canvasScreenRect.maxY),
                               forKey: "inputCenter")
            generator.setValue(style.checkerColorA, forKey: "inputColor0")
            generator.setValue(style.checkerColorB, forKey: "inputColor1")
            generator.setValue(style.checkerSquare * contentScale, forKey: "inputWidth")
            generator.setValue(1, forKey: "inputSharpness")
            checker = generator.outputImage?.cropped(to: checkerRect.intersection(viewPixelBounds)) ?? .empty()
        }
        let surround = CIImage(color: style.surroundColor).cropped(to: viewPixelBounds)
        return composite.composited(over: checker.composited(over: surround))
    }

    /// Merge down: the one destructive operation. Bakes both layers'
    /// transforms, masks, opacities, layer effects and the top layer's blend
    /// mode into a single new source image covering the union of their canvas
    /// bounds — including content outside the canvas, which survives the
    /// merge, and the reach of any layer effects (`styledCanvasBounds`), so a
    /// merged shadow is not cropped at the layer's edge.
    func renderMerged(bottom: Layer, top: Layer) -> (image: CGImage, origin: CGPoint)? {
        let union = bottom.styledCanvasBounds.union(top.styledCanvasBounds).integral
        guard !union.isEmpty, union.width >= 1, union.height >= 1 else { return nil }
        var accumulated = CIImage.empty()
        if top.isClippedToBelow && !bottom.isClippedToBelow {
            // Merging a clipped layer into its base bakes the confinement.
            // (Two clipped members of one run merge unconfined — their shared
            // base still confines the merged result at render time.) Over an
            // empty accumulator the base's own blend mode is a no-op, so the
            // baked pixels are exactly the group's content.
            accumulated = clippedGroupComposited(base: bottom, clipped: [top],
                                                 over: accumulated, outputTransform: .identity)
        } else {
            accumulated = layerComposited(bottom, over: accumulated, outputTransform: .identity)
            accumulated = layerComposited(top, over: accumulated, outputTransform: .identity)
        }
        let deep = bottom.source.bitsPerComponent > 8 || top.source.bitsPerComponent > 8
        guard let image = context.createCGImage(accumulated.cropped(to: union),
                                                from: union,
                                                format: deep ? .RGBA16 : .RGBA8,
                                                colorSpace: DezzyColorSpace.displayP3) else {
            return nil
        }
        return (image, union.origin)
    }

    // MARK: - Flattened output

    /// Renders the flattened canvas converted to `profile`.
    /// `matteWhite` composites over opaque white first (for JPEG, which has no
    /// alpha channel).
    func renderFlattened(document: Document,
                         profile: CGColorSpace,
                         sixteenBit: Bool,
                         matteWhite: Bool = false) -> CGImage? {
        var image = compositeImage(for: document)
        let rect = document.canvasRect.integral
        if matteWhite {
            let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1,
                                colorSpace: DezzyColorSpace.sRGB)!
            image = image.composited(over: CIImage(color: white).cropped(to: rect))
        }
        let format: CIFormat = sixteenBit ? .RGBA16 : .RGBA8
        return context.createCGImage(image, from: rect, format: format, colorSpace: profile)
    }

    // MARK: - Clipboard rendering

    /// A single layer's contribution — transform, enabled mask and opacity —
    /// rendered over transparency and cropped to `rect`. Deliberately NOT
    /// clipped to the canvas frame: content past the canvas edge survives a
    /// Copy, the same way `renderMerged` preserves it. `selection` optionally
    /// restricts the output to a canvas-space coverage texture positioned at
    /// `rect.origin` (a feathered selection copy).
    func renderLayerRegion(_ layer: Layer, croppedTo rect: CGRect,
                           selection: MaskTexture? = nil,
                           sixteenBit: Bool = false) -> CGImage? {
        // Copy takes the layer's OWN content: blend mode, clipping and layer
        // effects are all relationships with what surrounds the layer, which
        // a copy leaves behind (Photoshop's Copy is pixels, not style).
        // Forcing the solo copy onto the normal fast path also keeps copied
        // bytes exact (no gamma-sandwich round trip).
        var solo = layer
        solo.blendMode = .normal
        solo.isClippedToBelow = false
        solo.effects = .none
        return renderRegion(layerComposited(solo, over: .empty(), outputTransform: .identity),
                            croppedTo: rect, selection: selection, sixteenBit: sixteenBit)
    }

    /// The flattened visible composite over `rect` — clipped to the canvas
    /// frame like any flattened output, which is right for Copy Merged.
    func renderFlattenedRegion(document: Document, croppedTo rect: CGRect,
                               selection: MaskTexture? = nil,
                               sixteenBit: Bool = false) -> CGImage? {
        renderRegion(compositeImage(for: document),
                     croppedTo: rect, selection: selection, sixteenBit: sixteenBit)
    }

    private func renderRegion(_ source: CIImage, croppedTo rect: CGRect,
                              selection: MaskTexture?, sixteenBit: Bool) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        var image = source
        if let selection {
            image = Self.restricted(image, toSelection: selection, at: rect)
        }
        return context.createCGImage(image.cropped(to: rect), from: rect,
                                     format: sixteenBit ? .RGBA16 : .RGBA8,
                                     colorSpace: DezzyColorSpace.displayP3)
    }

    /// image × selection coverage (transparent outside). The texture is built
    /// per copy and discarded, so it deliberately bypasses the mask cache.
    private static func restricted(_ image: CIImage, toSelection texture: MaskTexture,
                                   at rect: CGRect) -> CIImage {
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return image }
        let mask = CIImage(bitmapData: texture.data, bytesPerRow: texture.width,
                           size: CGSize(width: texture.width, height: texture.height),
                           format: .L8, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        blend.setValue(image, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: rect),
                       forKey: kCIInputBackgroundImageKey)
        blend.setValue(mask, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? image
    }

    // MARK: - Colour sampling (eyedropper)

    /// The integer-aligned `size`×`size` canvas-pixel box centred on the pixel
    /// containing `point`, clipped to `bounds` (a box straddling the canvas
    /// edge keeps only its in-canvas portion). Nil when `point` lies outside
    /// `bounds`. Pure geometry — unit-tested separately, per the pattern.
    static func sampleBox(around point: CGPoint, size: Int, in bounds: CGRect) -> CGRect? {
        guard bounds.contains(point) else { return nil }
        let n = CGFloat(max(1, size))
        let box = CGRect(x: floor(point.x) - (n - 1) / 2,
                         y: floor(point.y) - (n - 1) / 2,
                         width: n, height: n)
            .intersection(bounds)
        guard box.width >= 1, box.height >= 1 else { return nil }
        return box
    }

    /// Averages the composite over a `size`×`size` canvas-pixel box centred on
    /// `point` (canvas space, y-up — the space `compositeImage` renders in, so
    /// no flip). Returns an sRGB colour, matching what the user sees and what
    /// the colour wells hold, or nil when `point` is outside the canvas,
    /// the document renders nothing, or the box is fully transparent. The box
    /// is clipped to the canvas edge and only the in-canvas portion is
    /// averaged. The graph is cropped to the box *before* rendering, so Core
    /// Image computes just those pixels — the whole canvas is never rendered
    /// to sample one point.
    func sampleColor(document: Document, at point: CGPoint, size: Int) -> CGColor? {
        guard let box = Self.sampleBox(around: point, size: size,
                                       in: document.canvasRect.integral) else { return nil }

        let composite = compositeImage(for: document)
        guard !composite.extent.isEmpty,
              let image = context.createCGImage(composite.cropped(to: box), from: box,
                                                format: .RGBA8,
                                                colorSpace: DezzyColorSpace.sRGB),
              image.bitsPerPixel == 32,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        // RGBA8 out of the CIContext is premultiplied; summing premultiplied
        // components and dividing by the alpha sum unpremultiplies the average
        // in one step, and uncovered pixels contribute nothing — which is what
        // "average only the in-canvas/covered portion" should mean.
        let premultiplied = image.alphaInfo == .premultipliedLast
            || image.alphaInfo == .premultipliedFirst
        var rSum = 0.0, gSum = 0.0, bSum = 0.0, aSum = 0.0
        for y in 0..<image.height {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<image.width {
                let p = row + x * 4
                let a = Double(p[3])
                let w = premultiplied ? 1.0 : a / 255
                rSum += Double(p[0]) * w
                gSum += Double(p[1]) * w
                bSum += Double(p[2]) * w
                aSum += a
            }
        }
        guard aSum > 0 else { return nil } // fully transparent — nothing to pick
        // The wells hold opaque colours, like Photoshop's eyedropper.
        return CGColor(srgbRed: min(1, rSum / aSum),
                       green: min(1, gSum / aSum),
                       blue: min(1, bSum / aSum),
                       alpha: 1)
    }
}
