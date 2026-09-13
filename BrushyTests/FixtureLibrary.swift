import CoreGraphics
import Foundation

/// Defines the golden fixtures and records them: deterministic input PNGs, the
/// JSON specs, and reference images (analytic / recorded / colorsync per
/// fixture — see FixtureSpec).
enum FixtureLibrary {
    static func recordAll() throws {
        try TestPaths.ensureDirs()
        try generateInputs()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for spec in makeSpecs() {
            let jsonURL = TestPaths.fixturesDir.appendingPathComponent("\(spec.name).json")
            try encoder.encode(spec).write(to: jsonURL)
            try record(spec)
        }
    }

    private static func record(_ spec: FixtureSpec) throws {
        let referenceURL = TestPaths.fixturesDir.appendingPathComponent(spec.reference)
        switch spec.referenceKind {
        case "analytic":
            let image = try ReferenceRenderer.render(spec: spec, fixturesDir: TestPaths.fixturesDir)
            try writePNG(image, to: referenceURL)
        case "recorded":
            let document = try spec.buildDocument(fixturesDir: TestPaths.fixturesDir)
            guard let image = RenderEngine.shared.renderFlattened(
                document: document, profile: spec.outputColorSpace, sixteenBit: false) else {
                throw TestImageError.contextFailed
            }
            try writePNG(image, to: referenceURL)
        case "colorsync":
            // Single-identity-layer fixtures only: the reference is the input
            // converted by ColorSync, independent of Core Image.
            guard spec.layers.count == 1 else { throw TestImageError.contextFailed }
            let input = try loadPNG(TestPaths.inputsDir
                .appendingPathComponent((spec.layers[0].source as NSString).lastPathComponent))
            let converted = try rawRGBA8(input, in: spec.outputColorSpace)
            let image = GeneratedImages.image(width: converted.width, height: converted.height,
                                              colorSpace: spec.outputColorSpace) { x, y in
                converted[x, y]
            }
            try writePNG(image, to: referenceURL)
        default:
            throw TestImageError.contextFailed
        }
    }

    // MARK: - Inputs

    private static func generateInputs() throws {
        let p3 = BrushyColorSpace.displayP3
        let srgb = BrushyColorSpace.sRGB
        var inputs: [String: CGImage] = [:]
        inputs["white-320x240-p3.png"] =
            GeneratedImages.solid(width: 320, height: 240, r: 255, g: 255, b: 255, colorSpace: p3)
        inputs["red-128x96-p3.png"] =
            GeneratedImages.solid(width: 128, height: 96, r: 255, g: 0, b: 0, colorSpace: p3)
        inputs["blue-200x120-p3.png"] =
            GeneratedImages.solid(width: 200, height: 120, r: 40, g: 90, b: 235, colorSpace: p3)
        inputs["teal-100x100-p3.png"] =
            GeneratedImages.solid(width: 100, height: 100, r: 0, g: 150, b: 150, colorSpace: p3)
        inputs["orange-80x80-p3.png"] =
            GeneratedImages.solid(width: 80, height: 80, r: 255, g: 140, b: 0, colorSpace: p3)
        inputs["gradcheck-640x480-srgb.png"] =
            GeneratedImages.gradientChecker(width: 640, height: 480, square: 32, colorSpace: srgb)
        inputs["gradcheck-200x150-srgb.png"] =
            GeneratedImages.gradientChecker(width: 200, height: 150, square: 16, colorSpace: srgb)
        inputs["p3bands-256x64-p3.png"] = GeneratedImages.image(width: 256, height: 64,
                                                                colorSpace: p3) { x, y in
            if y < 32 {
                return (UInt8(255 - x), UInt8(x), 0, 255) // P3 red → P3 green
            }
            return (UInt8(x), UInt8(x), UInt8(255 - x), 255) // P3 blue → P3 yellow
        }
        for (name, image) in inputs {
            try writePNG(image, to: TestPaths.inputsDir.appendingPathComponent(name))
        }
    }

    // MARK: - Specs (initial fixtures)

    private static func makeSpecs() -> [FixtureSpec] {
        var specs: [FixtureSpec] = []

        specs.append(FixtureSpec(
            name: "opacity-50",
            notes: "Layer at 50% opacity over an opaque background. Linear-light blend, verified analytically.",
            canvas: .init(width: 256, height: 192),
            outputProfile: "displayP3",
            referenceKind: "analytic",
            colorTolerance: 2, alphaTolerance: 0,
            layers: [
                .init(source: "inputs/white-320x240-p3.png",
                      transform: [1, 0, 0, 1, 0, 0], opacity: 1, visible: true, mask: nil),
                .init(source: "inputs/red-128x96-p3.png",
                      transform: [1, 0, 0, 1, 64, 48], opacity: 0.5, visible: true, mask: nil),
            ],
            reference: "references/opacity-50.png"))

        specs.append(FixtureSpec(
            name: "downscale-40",
            notes: "Layer downscaled to 40% (Lanczos path) and repositioned fractionally. Recorded regression reference.",
            canvas: .init(width: 320, height: 240),
            outputProfile: "sRGB",
            referenceKind: "recorded",
            colorTolerance: 2, alphaTolerance: 0,
            layers: [
                .init(source: "inputs/white-320x240-p3.png",
                      transform: [1, 0, 0, 1, 0, 0], opacity: 1, visible: true, mask: nil),
                .init(source: "inputs/gradcheck-640x480-srgb.png",
                      transform: [0.4, 0, 0, 0.4, 37.3, 21.7], opacity: 1, visible: true, mask: nil),
            ],
            reference: "references/downscale-40.png"))

        let rotation = CGAffineTransform(translationX: -100, y: -75)
            .concatenating(CGAffineTransform(rotationAngle: .pi / 6))
            .concatenating(CGAffineTransform(translationX: 160, y: 120))
        specs.append(FixtureSpec(
            name: "rotate-30",
            notes: "Layer rotated 30 degrees about its centre, placed at canvas centre. Recorded regression reference.",
            canvas: .init(width: 320, height: 240),
            outputProfile: "sRGB",
            referenceKind: "recorded",
            colorTolerance: 2, alphaTolerance: 0,
            layers: [
                .init(source: "inputs/white-320x240-p3.png",
                      transform: [1, 0, 0, 1, 0, 0], opacity: 1, visible: true, mask: nil),
                .init(source: "inputs/gradcheck-200x150-srgb.png",
                      transform: rotation.asArray, opacity: 1, visible: true, mask: nil),
            ],
            reference: "references/rotate-30.png"))

        specs.append(FixtureSpec(
            name: "crop-offframe",
            notes: "Canvas frames two layers partly out of frame (a crop's end state); transparent background, binary alpha, verified analytically.",
            canvas: .init(width: 200, height: 150),
            outputProfile: "displayP3",
            referenceKind: "analytic",
            colorTolerance: 2, alphaTolerance: 0,
            layers: [
                .init(source: "inputs/teal-100x100-p3.png",
                      transform: [1, 0, 0, 1, 150, 90], opacity: 1, visible: true, mask: nil),
                .init(source: "inputs/orange-80x80-p3.png",
                      transform: [1, 0, 0, 1, -30, -20], opacity: 1, visible: true, mask: nil),
            ],
            reference: "references/crop-offframe.png"))

        specs.append(FixtureSpec(
            name: "mask-feather-20",
            notes: "Rectangular mask with 20px feather (Gaussian sigma 10) over an opaque background. Closed-form erf reference. Selection rect is canvas-space, y-up.",
            canvas: .init(width: 300, height: 200),
            outputProfile: "displayP3",
            referenceKind: "analytic",
            colorTolerance: 2, alphaTolerance: 0,
            layers: [
                .init(source: "inputs/white-320x240-p3.png",
                      transform: [1, 0, 0, 1, 0, 0], opacity: 1, visible: true, mask: nil),
                .init(source: "inputs/blue-200x120-p3.png",
                      transform: [1, 0, 0, 1, 50, 40], opacity: 1, visible: true,
                      mask: .init(selectionRect: [80, 70, 140, 60], feather: 20)),
            ],
            reference: "references/mask-feather-20.png"))

        specs.append(FixtureSpec(
            name: "p3-to-srgb",
            notes: "Display P3 source exported to sRGB; reference converted by ColorSync, independent of Core Image.",
            canvas: .init(width: 256, height: 64),
            outputProfile: "sRGB",
            referenceKind: "colorsync",
            colorTolerance: 2, alphaTolerance: 0,
            layers: [
                .init(source: "inputs/p3bands-256x64-p3.png",
                      transform: [1, 0, 0, 1, 0, 0], opacity: 1, visible: true, mask: nil),
            ],
            reference: "references/p3-to-srgb.png"))

        return specs
    }
}
