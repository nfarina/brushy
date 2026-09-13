import Accelerate
import CoreGraphics
import Foundation

/// Builds mask textures (source resolution, white = opaque) from selections.
///
/// This is the choke point where a selection becomes coverage, and so the one
/// place that has to know a selection may carry an alpha channel: with one,
/// the channel is drawn through the layer transform; without one, the path is
/// filled, exactly as before.
enum MaskFactory {
    /// Rasterises a canvas-space selection into the layer's source space
    /// (selected area white, rest black) and applies the feather as a Gaussian
    /// falloff. Feather is specified in canvas pixels, Photoshop-style; the
    /// Gaussian sigma is feather/2, converted into source pixels through the
    /// layer's scale. An empty selection produces a reveal-all (all-white) mask.
    static func maskTexture(for layer: Layer,
                            selection: SelectionState,
                            featherCanvasPx: CGFloat) -> MaskTexture {
        let width = layer.source.width
        let height = layer.source.height
        guard let path = selection.path, layer.transform.isInvertible else {
            return MaskTexture(width: width, height: height, fill: 255)
        }

        var data = Data(count: width * height) // zero-filled = black = hidden
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: BrushyColorSpace.gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return
            }
            // Context space is source space; the inverse layer transform maps
            // canvas-space selection geometry into it.
            ctx.concatenate(layer.transform.inverted())
            if let alpha = selection.alpha {
                // The channel is the coverage, so it replaces the fill rather
                // than modulating it — see `SelectionState`. A scaled layer
                // resamples it here; a 1:1 one does not.
                if let image = alpha.texture.cgImage { ctx.draw(image, in: alpha.rect) }
            } else {
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.addPath(path)
                ctx.fillPath(using: .winding)
            }
        }

        var texture = MaskTexture(width: width, height: height, data: data)
        if featherCanvasPx > 0 {
            let (sx, sy) = layer.transform.scaleComponents
            let canvasPxPerSourcePx = max((sx + sy) / 2, 1e-4)
            let sigmaSourcePx = (featherCanvasPx / 2) / canvasPxPerSourcePx
            texture = blurred(texture, sigma: sigmaSourcePx)
        }
        return texture
    }

    /// Canvas-space selection coverage over `rect` (selected area white, rest
    /// black), feathered like masks — canvas pixels are the native unit
    /// here, so sigma is simply feather/2. Row 0 is the buffer's top row, like
    /// every mask buffer. Used by clipboard Copy / Copy Merged to restrict
    /// copied pixels to the selection.
    static func selectionTexture(rect: CGRect, selection: SelectionState,
                                 featherCanvasPx: CGFloat) -> MaskTexture {
        var texture = selection.coverageTexture(over: rect)
        if featherCanvasPx > 0 {
            texture = blurred(texture, sigma: featherCanvasPx / 2)
        }
        return texture
    }

    /// Exact separable discrete Gaussian blur, edge-extended.
    ///
    /// Pinned definition (the golden reference implements the same math
    /// independently): kernel radius ⌈3σ⌉, taps exp(-j²/2σ²) normalised to
    /// sum 1, convolved on a float plane in both axes, quantised to 8 bits
    /// once at the end. (CIGaussianBlur is a fast approximation that deviates
    /// a few /255 from a true Gaussian, which is why it isn't used here.)
    static func blurred(_ texture: MaskTexture, sigma requestedSigma: CGFloat) -> MaskTexture {
        guard requestedSigma > 0.01 else { return texture }
        let width = texture.width, height = texture.height
        // Past the buffer's own size the kernel is wider than anything it can
        // sample, so every extra tap is an edge-extended duplicate: the OUTPUT
        // stops changing while the cost keeps growing as O(radius). Measured
        // on a 64×64 mask, sigma 64 and sigma 512 agree to 0/255 per pixel.
        //
        // That matters because callers divide the feather by the layer's
        // scale, and `isInvertible` admits a determinant down to 1e-10 — so a
        // heavily downscaled layer at the maximum feather asks for sigma in
        // the millions. vImage does run it; it just takes ~3 s and ~150 MB per
        // call, on the interactive path that builds a mask from a selection,
        // for a result identical to the one below.
        let sigma = min(requestedSigma, CGFloat(max(width, height)))
        let kernel = gaussianKernel(sigma: Double(sigma))

        var src8 = texture.data
        var planeA = [Float](repeating: 0, count: width * height)
        var planeB = [Float](repeating: 0, count: width * height)
        var out8 = Data(count: width * height)

        let error: vImage_Error = src8.withUnsafeMutableBytes { srcRaw in
            planeA.withUnsafeMutableBufferPointer { aPtr in
                planeB.withUnsafeMutableBufferPointer { bPtr in
                    out8.withUnsafeMutableBytes { outRaw in
                        var src = vImage_Buffer(data: srcRaw.baseAddress,
                                                height: vImagePixelCount(height),
                                                width: vImagePixelCount(width),
                                                rowBytes: width)
                        var a = vImage_Buffer(data: aPtr.baseAddress,
                                              height: vImagePixelCount(height),
                                              width: vImagePixelCount(width),
                                              rowBytes: width * MemoryLayout<Float>.stride)
                        var b = vImage_Buffer(data: bPtr.baseAddress,
                                              height: vImagePixelCount(height),
                                              width: vImagePixelCount(width),
                                              rowBytes: width * MemoryLayout<Float>.stride)
                        var out = vImage_Buffer(data: outRaw.baseAddress,
                                                height: vImagePixelCount(height),
                                                width: vImagePixelCount(width),
                                                rowBytes: width)
                        var err = vImageConvert_Planar8toPlanarF(&src, &a, 1, 0, vImage_Flags(kvImageNoFlags))
                        guard err == kvImageNoError else { return err }
                        err = vImageConvolve_PlanarF(&a, &b, nil, 0, 0,
                                                     kernel, 1, UInt32(kernel.count),
                                                     0, vImage_Flags(kvImageEdgeExtend))
                        guard err == kvImageNoError else { return err }
                        err = vImageConvolve_PlanarF(&b, &a, nil, 0, 0,
                                                     kernel, UInt32(kernel.count), 1,
                                                     0, vImage_Flags(kvImageEdgeExtend))
                        guard err == kvImageNoError else { return err }
                        return vImageConvert_PlanarFtoPlanar8(&a, &out, 1, 0, vImage_Flags(kvImageNoFlags))
                    }
                }
            }
        }
        guard error == kvImageNoError else { return texture }
        return MaskTexture(width: width, height: height, data: out8)
    }

    static func gaussianKernel(sigma: Double) -> [Float] {
        // `ceil(3 * sigma)` is what makes the kernel size unbounded in sigma;
        // `saturatingInt` keeps a non-finite sigma from trapping here, and
        // `blurred` bounds the magnitude before it reaches this point.
        let radius = max(1, (3 * sigma).rounded(.up).saturatingInt)
        var taps = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        return taps.map { Float($0) }
    }
}
