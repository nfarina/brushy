import CoreGraphics
import Foundation

/// JSON description of a golden-image fixture: the operations that produce
/// the composite, alongside a reference PNG.
///
/// Geometry convention: canvas space, origin bottom-left, y-up — the model's
/// own coordinate system. `referenceKind` records how the reference was made:
///   - "analytic":  independent CPU renderer (double precision, closed-form
///                  feather math). Verifies absolute correctness.
///   - "recorded":  produced by this app's own pipeline at record time.
///                  Regression fixture for resampling paths whose kernels have
///                  no closed form (Lanczos, rotation).
///   - "colorsync": produced by ColorSync (CoreGraphics) conversion,
///                  independent of the Core Image path under test.
struct FixtureSpec: Codable {
    struct CanvasSpec: Codable {
        var width: Int
        var height: Int
    }

    struct MaskSpec: Codable {
        /// [x, y, w, h] in canvas space (y-up).
        var selectionRect: [Double]
        /// Feather in canvas pixels (Gaussian sigma = feather/2).
        var feather: Double
    }

    struct LayerSpec: Codable {
        var source: String
        /// [a, b, c, d, tx, ty]
        var transform: [Double]
        var opacity: Double?
        var visible: Bool?
        var mask: MaskSpec?
    }

    var name: String
    var notes: String?
    var canvas: CanvasSpec
    var outputProfile: String // "sRGB" | "displayP3"
    var referenceKind: String // "analytic" | "recorded" | "colorsync"
    var colorTolerance: Int?
    var alphaTolerance: Int?
    var layers: [LayerSpec]
    var reference: String

    var outputColorSpace: CGColorSpace {
        outputProfile == "displayP3" ? DezzyColorSpace.displayP3 : DezzyColorSpace.sRGB
    }
}

extension FixtureSpec {
    /// Builds a real `Document` through the production import and mask paths.
    func buildDocument(fixturesDir: URL) throws -> Document {
        var document = Document(canvasSize: CGSize(width: canvas.width, height: canvas.height))
        for layerSpec in layers {
            let url = fixturesDir.appendingPathComponent(layerSpec.source)
            let source = try ImageImporter.importImage(at: url)
            guard let transform = CGAffineTransform(array: layerSpec.transform) else {
                throw TestImageError.loadFailed(url)
            }
            var layer = Layer(name: layerSpec.source, source: source, transform: transform)
            layer.opacity = Float(layerSpec.opacity ?? 1)
            layer.isVisible = layerSpec.visible ?? true
            if let maskSpec = layerSpec.mask, maskSpec.selectionRect.count == 4 {
                let r = maskSpec.selectionRect
                let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
                let texture = MaskFactory.maskTexture(
                    for: layer,
                    selection: SelectionState(path: CGPath(rect: rect, transform: nil)),
                    featherCanvasPx: maskSpec.feather)
                layer.mask = Mask(texture: texture, isEnabled: true)
            }
            document.layers.append(layer)
        }
        return document
    }
}
