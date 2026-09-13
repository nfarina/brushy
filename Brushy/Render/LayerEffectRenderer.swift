import CoreGraphics
import CoreImage
import Foundation

/// Renders a layer's effects (Photoshop's Layer Style) as Core Image nodes,
/// on the same rebuilt-per-frame basis as the rest of — no cached
/// intermediates, ROI-limited like everything else.
///
/// **The two halves.** Photoshop composites each effect against the backdrop
/// with the effect's own blend mode, in a fixed order. Two of the seven land
/// *outside* the layer's coverage and therefore meet the backdrop directly —
/// Drop Shadow and Outer Glow. Those come back from `exteriorPasses(...)` and
/// the render engine blends each onto the accumulator with its own mode
/// before the layer itself. The other five live inside the layer's coverage,
/// where the thing they meet is the layer's own pixels, so `styledFill(...)`
/// folds them into one image that then blends onto the accumulator with the
/// LAYER's mode. Drawing order is Photoshop's, bottom-up:
///
///   drop shadow → outer glow → | gradient overlay → colour overlay →
///   inner glow → inner shadow → stroke
///
/// (Photoshop's fx list reads top-down, so this is that list reversed.)
///
/// The one deliberate approximation: an outside Stroke with a non-Normal
/// blend mode blends against the layer's styled fill rather than the
/// backdrop, because it is inside the same image. At the default Normal/100%
/// — and for inside/centre strokes at any mode — the result is exact.
///
/// **Spaces.** `content` arrives already in the output space (the layer's
/// transform folded into the view/export transform, per `RenderEngine`), so
/// effect parameters, which are canvas-space points, scale by `scale`. That
/// is what keeps an effect independent of the layer's own scale, the way
/// Photoshop's document-pixel effects are. Offsets assume the output
/// transform carries no rotation, which is true of the viewport and of
/// export (identity).
///
/// **Colour.** Effect colours are sRGB (like the tool colour wells) and
/// enter the graph through `CIImage(color:)`, which colour-matches them into
/// the linear working space. Blurs and morphology run on premultiplied
/// constant-colour silhouettes, where the only varying channel is alpha —
/// alpha carries no transfer function, so blurring in linear light is not the
/// gamma error it would be for real image content. Effect-to-backdrop and
/// effect-to-fill blends go through `RenderEngine.blended`, which applies
/// Photoshop's gamma-encoded blend arithmetic.
enum LayerEffectRenderer {
    /// An effect that composites against the BACKDROP, not the layer.
    struct Pass {
        var image: CIImage
        var mode: BlendMode
        var opacity: Double
    }

    /// CIGaussianBlur's `inputRadius` in terms of Photoshop's Size. Measured
    /// on this pipeline: a radius-r blur of a hard edge fades to zero at
    /// about 2.5·r pixels (so CI's radius ≈ 1.25σ), and Photoshop's Size is
    /// the distance at which the matte has effectively died out — hence
    /// 1/2.5. Pinned by `LayerEffectsTests.testShadowSizeControlsReach`.
    static let blurRadiusPerSize: CGFloat = 0.4

    // MARK: - Entry points

    /// Effects that render behind the layer, bottom-first.
    static func exteriorPasses(_ effects: LayerEffects, content: CIImage,
                               scale: CGFloat) -> [Pass] {
        guard let bounds = workingBounds(effects, content: content, scale: scale) else { return [] }
        var passes: [Pass] = []
        if let shadow = effects.enabledDropShadow {
            let offset = shadowOffset(angle: shadow.usesGlobalLight
                                        ? effects.globalLightAngle : shadow.angle,
                                      distance: shadow.distance, scale: scale)
            var image = exteriorMatte(content: content, color: shadow.color,
                                      offset: offset, spread: shadow.spread,
                                      size: shadow.size, scale: scale, bounds: bounds)
            if shadow.knocksOut {
                // Photoshop's "Layer Knocks Out Drop Shadow": the layer's own
                // coverage is punched out, so a translucent layer shows the
                // backdrop through itself, not its own shadow.
                image = RenderEngine.alphaMasked(image, by: invertedCoverage(of: content),
                                                 within: bounds)
            }
            passes.append(Pass(image: image, mode: shadow.blendMode, opacity: shadow.opacity))
        }
        if let glow = effects.enabledOuterGlow {
            let image = exteriorMatte(content: content, color: glow.color,
                                      offset: .zero, spread: glow.spread,
                                      size: glow.size, scale: scale, bounds: bounds)
            passes.append(Pass(image: image, mode: glow.blendMode, opacity: glow.opacity))
        }
        return passes
    }

    /// The layer's pixels with every interior effect folded in. Returns
    /// `content` untouched when nothing interior is enabled.
    static func styledFill(_ effects: LayerEffects, content: CIImage,
                           scale: CGFloat) -> CIImage {
        guard let bounds = workingBounds(effects, content: content, scale: scale) else {
            return content
        }
        var image = content

        if let overlay = effects.enabledGradientOverlay {
            let gradient = gradientImage(overlay, bounds: content.extent, scale: scale)
            let confined = RenderEngine.alphaMasked(gradient, by: RenderEngine.alphaCoverage(of: content),
                                                    within: content.extent)
            image = RenderEngine.blended(RenderEngine.withOpacity(confined, Float(overlay.opacity)),
                                         over: image, mode: overlay.blendMode)
        }
        if let overlay = effects.enabledColorOverlay {
            let fill = silhouette(of: content, color: overlay.color, within: content.extent)
            image = RenderEngine.blended(RenderEngine.withOpacity(fill, Float(overlay.opacity)),
                                         over: image, mode: overlay.blendMode)
        }
        if let glow = effects.enabledInnerGlow {
            let matte = interiorMatte(content: content, color: glow.color, offset: .zero,
                                      choke: glow.choke, size: glow.size,
                                      scale: scale, bounds: bounds)
            image = RenderEngine.blended(RenderEngine.withOpacity(matte, Float(glow.opacity)),
                                         over: image, mode: glow.blendMode)
        }
        if let shadow = effects.enabledInnerShadow {
            let offset = shadowOffset(angle: shadow.usesGlobalLight
                                        ? effects.globalLightAngle : shadow.angle,
                                      distance: shadow.distance, scale: scale)
            let matte = interiorMatte(content: content, color: shadow.color, offset: offset,
                                      choke: shadow.choke, size: shadow.size,
                                      scale: scale, bounds: bounds)
            image = RenderEngine.blended(RenderEngine.withOpacity(matte, Float(shadow.opacity)),
                                         over: image, mode: shadow.blendMode)
        }
        if let stroke = effects.enabledStroke {
            let band = strokeMatte(content: content, stroke: stroke, scale: scale, bounds: bounds)
            image = RenderEngine.blended(RenderEngine.withOpacity(band, Float(stroke.opacity)),
                                         over: image, mode: stroke.blendMode)
        }
        return image
    }

    // MARK: - Mattes

    /// A shadow/glow lying outside the layer: the coverage, choked by
    /// `spread`, blurred by the remainder of `size`, displaced by `offset`.
    private static func exteriorMatte(content: CIImage, color: EffectColor,
                                      offset: CGVector, spread: Double, size: Double,
                                      scale: CGFloat, bounds: CGRect) -> CIImage {
        var matte = silhouette(of: content, color: color, within: bounds)
        matte = spreadAndBlur(matte, spread: spread, size: size, scale: scale)
        if offset != .zero {
            matte = matte.transformed(by: CGAffineTransform(translationX: offset.dx, y: offset.dy))
        }
        return matte.cropped(to: bounds)
    }

    /// A shadow/glow lying inside the layer: the same construction cast by the
    /// *hole* around the layer (so it grows inward from the edge), then
    /// confined to the layer's coverage.
    private static func interiorMatte(content: CIImage, color: EffectColor,
                                      offset: CGVector, choke: Double, size: Double,
                                      scale: CGFloat, bounds: CGRect) -> CIImage {
        // Colour everywhere the layer ISN'T, across the working bounds — the
        // matte has to exist beyond the layer's edge for the blur to have
        // something to bring inward.
        var matte = RenderEngine.alphaMasked(CIImage(color: ciColor(color)),
                                             by: invertedCoverage(of: content), within: bounds)
        matte = spreadAndBlur(matte, spread: choke, size: size, scale: scale)
        if offset != .zero {
            matte = matte.transformed(by: CGAffineTransform(translationX: offset.dx, y: offset.dy))
        }
        return RenderEngine.alphaMasked(matte, by: RenderEngine.alphaCoverage(of: content),
                                        within: content.extent)
    }

    /// The stroke band. Outside/centre grow the coverage and punch out the
    /// interior; inside keeps the coverage and punches out an eroded copy.
    private static func strokeMatte(content: CIImage, stroke: StrokeEffect,
                                    scale: CGFloat, bounds: CGRect) -> CIImage {
        let width = CGFloat(stroke.size) * scale
        guard width > 0 else { return CIImage.empty() }
        let base = silhouette(of: content, color: stroke.color, within: bounds)
        let outerRadius: CGFloat
        let holeRadius: CGFloat
        switch stroke.position {
        case .outside: outerRadius = width; holeRadius = 0
        case .inside: outerRadius = 0; holeRadius = width
        case .center: outerRadius = width / 2; holeRadius = width / 2
        }
        let outer = dilated(base, radius: outerRadius)
        let hole = holeRadius > 0 ? eroded(base, radius: holeRadius) : content
        return RenderEngine.alphaMasked(outer, by: invertedCoverage(of: hole), within: bounds)
    }

    /// Photoshop's Spread/Choke: the fraction of Size spent dilating the
    /// matte before the blur, which hardens its edge. Spread 100% is a pure
    /// dilation with no blur at all.
    private static func spreadAndBlur(_ image: CIImage, spread: Double, size: Double,
                                      scale: CGFloat) -> CIImage {
        let clamped = min(max(spread, 0), 1)
        let sizeInPixels = CGFloat(max(size, 0)) * scale
        var matte = dilated(image, radius: sizeInPixels * CGFloat(clamped))
        let blurRadius = sizeInPixels * CGFloat(1 - clamped) * blurRadiusPerSize
        if blurRadius >= 0.1, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(matte, forKey: kCIInputImageKey)
            blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
            matte = blur.outputImage ?? matte
        }
        return matte
    }

    // MARK: - Primitives

    /// `color` painted through the image's coverage: a premultiplied,
    /// constant-colour copy of its alpha.
    private static func silhouette(of image: CIImage, color: EffectColor,
                                   within rect: CGRect) -> CIImage {
        RenderEngine.alphaMasked(CIImage(color: ciColor(color)),
                                 by: RenderEngine.alphaCoverage(of: image), within: rect)
    }

    /// 1 − α as an opaque grayscale, the complement of
    /// `RenderEngine.alphaCoverage`. Infinite extent, fully white outside the
    /// image — which is what "everywhere the layer isn't" has to mean.
    static func invertedCoverage(of image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return image }
        let negativeAlpha = CIVector(x: 0, y: 0, z: 0, w: -1)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(negativeAlpha, forKey: "inputRVector")
        filter.setValue(negativeAlpha, forKey: "inputGVector")
        filter.setValue(negativeAlpha, forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputAVector")
        filter.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputBiasVector")
        return filter.outputImage ?? image
    }

    private static func dilated(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard radius >= 0.5, let filter = CIFilter(name: "CIMorphologyMaximum") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage ?? image
    }

    private static func eroded(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard radius >= 0.5, let filter = CIFilter(name: "CIMorphologyMinimum") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        return filter.outputImage ?? image
    }

    private static func ciColor(_ color: EffectColor) -> CIColor {
        CIColor(cgColor: color.cgColor)
    }

    /// The colour's DOCUMENT-space (gamma-encoded Display P3) components,
    /// handed to Core Image as if they were linear so the generator
    /// interpolates them untouched. `RenderEngine.gammaDecoded` puts the
    /// finished ramp back into linear light — see `gradientImage`.
    private static func encodedRampColor(_ color: EffectColor) -> CIColor {
        let encoded = color.cgColor.converted(to: BrushyColorSpace.displayP3,
                                              intent: .defaultIntent, options: nil)
        let c = encoded?.components ?? [0, 0, 0, 1]
        guard c.count >= 3 else { return ciColor(color) }
        return CIColor(red: c[0], green: c[1], blue: c[2], alpha: 1,
                       colorSpace: BrushyColorSpace.linearWorking) ?? ciColor(color)
    }

    /// Photoshop's angle dial points at the light; the shadow falls the other
    /// way. Canvas space is y-up, so 120° (the default) lands the shadow down
    /// and to the right, exactly as Photoshop draws it.
    static func shadowOffset(angle: Double, distance: Double, scale: CGFloat) -> CGVector {
        let radians = angle * .pi / 180
        let length = CGFloat(distance) * scale
        return CGVector(dx: -cos(radians) * length, dy: -sin(radians) * length)
    }

    /// The rect every intermediate is confined to: the layer's coverage grown
    /// by the furthest any enabled effect reaches. Nil when the content has no
    /// usable extent (an empty or infinite-extent layer), which tells the
    /// callers to leave the layer alone.
    private static func workingBounds(_ effects: LayerEffects, content: CIImage,
                                      scale: CGFloat) -> CGRect? {
        let extent = content.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        // Interior effects are cast by the hole AROUND the layer, so the
        // working rect has to reach that far outside too — otherwise an inner
        // shadow has no matte to bring inward and silently renders nothing.
        let outset = max(effects.outsetInCanvasPoints,
                         effects.interiorSourceReachInCanvasPoints) * scale
        // A couple of pixels of slack keeps the blur's own falloff from being
        // clipped at the edge of the matte.
        return extent.insetBy(dx: -(outset + 2), dy: -(outset + 2))
    }

    // MARK: - Gradient overlay

    /// The ramp, unconfined, covering `bounds`. Geometry follows Photoshop:
    /// the ramp is centred on the layer's bounds and spans them along `angle`
    /// (scaled by Scale); a radial ramp runs from the centre outward.
    ///
    /// Interpolation happens on GAMMA-ENCODED values, like Photoshop's, not
    /// in the linear working space — a black→white ramp is mid-grey at its
    /// midpoint, where linear-light interpolation would put a washed-out 188.
    /// Same reconciliation as the blend modes (`RenderEngine.blended`): the
    /// stops enter as encoded numbers and the finished ramp is decoded back
    /// into linear light.
    private static func gradientImage(_ overlay: GradientOverlayEffect,
                                      bounds: CGRect, scale: CGFloat) -> CIImage {
        var startColor = encodedRampColor(overlay.startColor)
        var endColor = encodedRampColor(overlay.endColor)
        if overlay.reversed { swap(&startColor, &endColor) }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radians = overlay.angle * .pi / 180
        let direction = CGVector(dx: cos(radians), dy: sin(radians))
        // The bounds' own extent along the ramp direction — a 0°/90° ramp
        // spans the width/height exactly, like Photoshop's.
        let span = abs(bounds.width * direction.dx) + abs(bounds.height * direction.dy)
        let length = max(span * CGFloat(max(overlay.scale, 0.01)), 1)

        switch overlay.style {
        case .linear:
            guard let filter = CIFilter(name: "CILinearGradient") else { return .empty() }
            filter.setValue(CIVector(x: center.x - direction.dx * length / 2,
                                     y: center.y - direction.dy * length / 2), forKey: "inputPoint0")
            filter.setValue(CIVector(x: center.x + direction.dx * length / 2,
                                     y: center.y + direction.dy * length / 2), forKey: "inputPoint1")
            filter.setValue(startColor, forKey: "inputColor0")
            filter.setValue(endColor, forKey: "inputColor1")
            return RenderEngine.gammaDecoded((filter.outputImage ?? .empty()).cropped(to: bounds))
        case .radial:
            guard let filter = CIFilter(name: "CIRadialGradient") else { return .empty() }
            filter.setValue(CIVector(x: center.x, y: center.y), forKey: "inputCenter")
            filter.setValue(0, forKey: "inputRadius0")
            filter.setValue(max(bounds.width, bounds.height) / 2
                            * CGFloat(max(overlay.scale, 0.01)), forKey: "inputRadius1")
            filter.setValue(startColor, forKey: "inputColor0")
            filter.setValue(endColor, forKey: "inputColor1")
            return RenderEngine.gammaDecoded((filter.outputImage ?? .empty()).cropped(to: bounds))
        }
    }
}
