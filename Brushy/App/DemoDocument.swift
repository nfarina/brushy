import AppKit
import CoreGraphics

/// The Phase 0 deliverable: `--demo` opens a window displaying a hardcoded
/// two-layer composite (gradient background + rotated half-transparent checker)
/// driven through the real pipeline.
enum DemoDocumentFactory {
    static func openDemoDocument() {
        guard let document = (try? NSDocumentController.shared
            .openUntitledDocumentAndDisplay(true)) as? BrushyDocument else { return }

        var demo = Document(canvasSize: CGSize(width: 800, height: 600))
        let background = Layer(
            name: "Background",
            source: GeneratedImages.horizontalGradient(
                width: 800, height: 600,
                from: (28, 60, 130), to: (242, 150, 40),
                colorSpace: BrushyColorSpace.displayP3))

        var checker = Layer(
            name: "Checker",
            source: GeneratedImages.gradientChecker(
                width: 300, height: 300, square: 25,
                colorSpace: BrushyColorSpace.sRGB))
        checker.transform = CGAffineTransform(translationX: -150, y: -150)
            .concatenating(CGAffineTransform(rotationAngle: .pi / 6))
            .concatenating(CGAffineTransform(translationX: 400, y: 300))
        checker.opacity = 0.55

        demo.layers = [background, checker]
        document.store.replaceDocument(demo,
                                       actionName: DocumentStore.newDocumentActionName)
    }
}
