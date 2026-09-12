import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a tool hands back: text for the model, an optional image for the
/// model, and what the sidebar should show.
struct ToolOutcome {
    var text: String
    var image: (mime: String, data: Data)?
    var status: ToolCallRecord.Status
    /// Bytes for the sidebar thumbnail (a look rendering, a generated image).
    var displayImage: Data?
}

/// The three tools. `execute` is the workhorse; `look` and `generate_image`
/// exist because a script can't see and can't paint.
@MainActor
final class ChatTools {
    let registry: DocumentRegistry
    let runner: ScriptRunner
    /// Nil when no key is configured; the tool then reports that.
    var imageClient: () -> GeminiClient? = { nil }
    var imageModel: () -> String = { "gemini-3.1-flash-image" }

    init(registry: DocumentRegistry, runner: ScriptRunner) {
        self.registry = registry
        self.runner = runner
    }

    static let executeName = "execute"
    static let lookName = "look"
    static let generateImageName = "generate_image"

    static let declarations: [ToolDeclaration] = [
        ToolDeclaration(
            name: executeName,
            description: "Run JavaScript against the open documents using the dezzy API (see the system prompt). Changes apply atomically as one undo step per document when the script returns; if it throws, nothing changes. Returns the script's return value, console output, and a summary of what changed.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object(["type": .string("string"),
                                     "description": .string("The JavaScript to run. `doc` is the active document; `dezzy.doc(\"doc2\")` reaches others. Use `return` to report a value.")]),
                    "description": .object(["type": .string("string"),
                                            "description": .string("What the script does, in a few words — becomes the undo step's name, e.g. \"Arrange screenshots in a row\".")]),
                ]),
                "required": .array([.string("code"), .string("description")]),
            ])),
        ToolDeclaration(
            name: lookName,
            description: "Render a document (the composite of all visible layers) or a single layer to an image so you can see it. Transparent areas are shown as white.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "document": .object(["type": .string("string"),
                                         "description": .string("Document id, e.g. \"doc1\". Defaults to the active document.")]),
                    "layer": .object(["type": .string("string"),
                                      "description": .string("A layer id or name to render alone (its own pixels, no blending). Omit for the whole document.")]),
                    "max_size": .object(["type": .string("integer"),
                                         "description": .string("Longest edge of the returned image in pixels (default 1024).")]),
                ]),
            ])),
        ToolDeclaration(
            name: generateImageName,
            description: "Generate an image with an image model and place it as a new layer. Optionally give reference layers whose content guides the generation (e.g. to restyle or extend something). Use execute afterwards to move or resize the result.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "prompt": .object(["type": .string("string"), "description": .string("What to generate.")]),
                    "document": .object(["type": .string("string"), "description": .string("Target document id; defaults to the active document.")]),
                    "x": .object(["type": .string("number"), "description": .string("Top-left x of the placement box (default: centred).")]),
                    "y": .object(["type": .string("number"), "description": .string("Top-left y of the placement box.")]),
                    "width": .object(["type": .string("number"), "description": .string("Placement box width; the image is generated at the nearest aspect ratio and scaled to fit the box.")]),
                    "height": .object(["type": .string("number"), "description": .string("Placement box height.")]),
                    "reference_layers": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                                 "description": .string("Layer ids or names to send as reference images.")]),
                    "name": .object(["type": .string("string"), "description": .string("Name for the new layer.")]),
                ]),
                "required": .array([.string("prompt")]),
            ])),
    ]

    func run(_ call: FunctionCall) async -> ToolOutcome {
        switch call.name {
        case Self.executeName: return await execute(call)
        case Self.lookName: return await look(call)
        case Self.generateImageName: return await generateImage(call)
        default:
            return ToolOutcome(text: "Unknown tool \"\(call.name)\"", image: nil, status: .failed)
        }
    }

    // MARK: - execute

    private func execute(_ call: FunctionCall) async -> ToolOutcome {
        guard let code = call.string("code"), !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolOutcome(text: "Missing code.", image: nil, status: .failed)
        }
        let description = call.string("description").flatMap { $0.isEmpty ? nil : $0 } ?? "Script"
        let result = await withCheckedContinuation { continuation in
            runner.run(code: code, description: description) { continuation.resume(returning: $0) }
        }
        return Self.outcome(for: result)
    }

    static func outcome(for result: ScriptRunner.Result) -> ToolOutcome {
        var lines: [String] = []
        let outcome = result.outcome
        if let failure = outcome.failure {
            if let line = failure.line {
                lines.append("Error on line \(line): \(failure.message)")
            } else {
                lines.append("Error: \(failure.message)")
            }
            if !outcome.logs.isEmpty { lines.append("Console:\n" + outcome.logs.joined(separator: "\n")) }
            lines.append("Nothing was applied.")
            return ToolOutcome(text: lines.joined(separator: "\n"), image: nil, status: .failed)
        }
        if result.conflicted {
            return ToolOutcome(text: "The document changed while the script was running, so nothing was applied. Re-read the context and try again.",
                               image: nil, status: .failed)
        }
        if result.changes.isEmpty {
            lines.append("OK — no document was changed.")
        } else {
            lines.append("OK. " + result.changes.map { "\($0.id) \"\($0.title)\": \($0.summary)" }.joined(separator: " | "))
        }
        if !(outcome.returnValue is NSNull) {
            lines.append("Returned: " + JSONValue(any: outcome.returnValue).jsonString)
        }
        if !outcome.logs.isEmpty { lines.append("Console:\n" + outcome.logs.joined(separator: "\n")) }
        for change in result.changes {
            lines.append("Now:\n" + change.after)
        }
        return ToolOutcome(text: lines.joined(separator: "\n"), image: nil, status: .succeeded)
    }

    // MARK: - look

    private func resolveStore(_ call: FunctionCall) -> (id: String, store: DocumentStore)? {
        if let id = call.string("document"), !id.isEmpty {
            return registry.store(for: id).map { (id, $0) }
        }
        guard let id = registry.activeID(), let store = registry.store(for: id) else { return nil }
        return (id, store)
    }

    private func look(_ call: FunctionCall) async -> ToolOutcome {
        guard let (id, store) = resolveStore(call) else {
            return ToolOutcome(text: "No such document is open.", image: nil, status: .failed)
        }
        store.commitPendingSessions()
        let document = store.document
        let maxSide = CGFloat(call.double("max_size") ?? 1024).clamped(to: 64...2048)
        var target: Layer?
        if let ref = call.string("layer"), !ref.isEmpty {
            let ids = ScriptState.IDMap(document)
            let uuid = ids.layers[ref] ?? document.layers.last(where: { $0.name == ref })?.id
                ?? document.layers.last(where: { $0.name.lowercased() == ref.lowercased() })?.id
            guard let uuid, let layer = document[layerID: uuid] else {
                return ToolOutcome(text: "No layer \"\(ref)\" in \(id).", image: nil, status: .failed)
            }
            target = layer
        }
        let rendered: CGImage? = await Task.detached(priority: .userInitiated) {
            if let target { return ChatRenderer.layer(target, maxSide: maxSide) }
            return ChatRenderer.composite(document, maxSide: maxSide)
        }.value
        guard let rendered, let png = ChatRenderer.png(rendered) else {
            return ToolOutcome(text: "Rendering failed.", image: nil, status: .failed)
        }
        let what: String
        if let target {
            let frame = ScriptGeometry.topLeft(target.canvasBounds, canvasHeight: document.canvasSize.height)
            what = "Layer \"\(target.name)\" of \(id), which sits at (\(Int(frame.minX)), \(Int(frame.minY))) \(Int(frame.width))×\(Int(frame.height)) on the canvas"
        } else {
            what = "\(id) composite (\(Int(document.canvasSize.width))×\(Int(document.canvasSize.height)) px)"
        }
        let text = "\(what), rendered at \(rendered.width)×\(rendered.height). Transparent areas appear white."
        return ToolOutcome(text: text, image: ("image/png", png), status: .succeeded, displayImage: png)
    }

    // MARK: - generate_image

    static let aspectRatios: [(name: String, value: Double)] = [
        ("1:1", 1), ("3:2", 1.5), ("2:3", 2.0 / 3), ("3:4", 0.75), ("4:3", 4.0 / 3),
        ("4:5", 0.8), ("5:4", 1.25), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9), ("21:9", 21.0 / 9),
    ]

    nonisolated static func nearestAspectRatio(_ ratio: Double) -> String {
        aspectRatios.min { abs(log($0.value) - log(ratio)) < abs(log($1.value) - log(ratio)) }!.name
    }

    nonisolated static func imageSize(forLongestEdge px: Double) -> String {
        if px <= 512 { return "512" }
        if px <= 1024 { return "1K" }
        return "2K"
    }

    private func generateImage(_ call: FunctionCall) async -> ToolOutcome {
        guard let prompt = call.string("prompt"), !prompt.isEmpty else {
            return ToolOutcome(text: "Missing prompt.", image: nil, status: .failed)
        }
        guard let client = imageClient() else {
            return ToolOutcome(text: GeminiError.missingKey.localizedDescription, image: nil, status: .failed)
        }
        guard let (id, store) = resolveStore(call) else {
            return ToolOutcome(text: "No such document is open.", image: nil, status: .failed)
        }
        store.commitPendingSessions()
        let document = store.document
        let canvas = document.canvasSize
        let width = call.double("width"), height = call.double("height")
        let box = CGSize(width: width ?? (height.map { $0 * Double(canvas.width / canvas.height) } ?? Double(canvas.width)),
                         height: height ?? (width.map { $0 * Double(canvas.height / canvas.width) } ?? Double(canvas.height)))
        let ratio = Self.nearestAspectRatio(Double(box.width / max(box.height, 1)))
        let size = Self.imageSize(forLongestEdge: Double(max(box.width, box.height)))

        // Reference layers → JPEG.
        var references: [Data] = []
        var referenceNames: [String] = []
        if let refs = call.arguments["reference_layers"]?.arrayValue {
            let ids = ScriptState.IDMap(document)
            for ref in refs.compactMap(\.stringValue) {
                let uuid = ids.layers[ref] ?? document.layers.last(where: { $0.name == ref })?.id
                guard let uuid, let layer = document[layerID: uuid] else {
                    return ToolOutcome(text: "No layer \"\(ref)\" in \(id).", image: nil, status: .failed)
                }
                let image = await Task.detached(priority: .userInitiated) {
                    ChatRenderer.layer(layer, maxSide: 1024)
                }.value
                if let image, let jpeg = ChatRenderer.jpeg(image, quality: 0.9) {
                    references.append(jpeg)
                    referenceNames.append(layer.name)
                }
            }
        }

        let data: Data
        do {
            data = try await client.generateImage(model: imageModel(), prompt: prompt, references: references,
                                                  aspectRatio: ratio, imageSize: size)
        } catch {
            return ToolOutcome(text: "Image generation failed: \(error.localizedDescription)", image: nil, status: .failed)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return ToolOutcome(text: "The generated image could not be decoded.", image: nil, status: .failed)
        }
        let image = ImageImporter.normalize(raw)
        let name = call.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? "Generated: " + String(prompt.prefix(24))
        var placement: [String: Any] = ["name": name]
        if let x = call.double("x") { placement["x"] = x }
        if let y = call.double("y") { placement["y"] = y }
        if width != nil || height != nil {
            placement["width"] = box.width
            placement["height"] = box.height
        }
        let options = JSONValue(any: placement).jsonString
        let code = "dezzy.doc(\"\(id)\").addImage(\"generated\", \(options));"
        let description = "Generate image: " + String(prompt.prefix(40))
        let result = await withCheckedContinuation { continuation in
            runner.run(code: code, description: description, images: ["generated": image]) {
                continuation.resume(returning: $0)
            }
        }
        var outcome = Self.outcome(for: result)
        if outcome.status == .succeeded {
            var text = "Generated a \(image.width)×\(image.height) image (\(ratio))"
            if !referenceNames.isEmpty { text += " guided by " + referenceNames.map { "\"\($0)\"" }.joined(separator: ", ") }
            outcome.text = text + " and placed it. " + outcome.text
        }
        outcome.displayImage = data
        return outcome
    }
}

/// Off-main rendering for the tools: the `Document` value is snapshotted on
/// main and rendered on a background task, the sanctioned pattern (§3).
enum ChatRenderer {
    static func composite(_ document: Document, maxSide: CGFloat) -> CGImage? {
        let canvas = document.canvasRect.integral
        guard canvas.width >= 1, canvas.height >= 1 else { return nil }
        let scale = min(1, maxSide / max(canvas.width, canvas.height))
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let engine = RenderEngine.shared
        var image = engine.compositeImage(for: document, outputTransform: transform)
        let rect = canvas.applying(transform).integral
        let white = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: DezzyColorSpace.sRGB)!
        image = image.composited(over: CIImage(color: white).cropped(to: rect))
        return engine.context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: DezzyColorSpace.sRGB)
    }

    static func layer(_ layer: Layer, maxSide: CGFloat) -> CGImage? {
        let bounds = layer.canvasBounds.integral
        guard bounds.width >= 1, bounds.height >= 1,
              let full = RenderEngine.shared.renderLayerRegion(layer, croppedTo: bounds) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(full.width, full.height)))
        guard scale < 1 else { return full }
        let width = max(1, Int((CGFloat(full.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(full.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: DezzyColorSpace.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        encode(image, type: UTType.png, properties: nil)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        // JPEG has no alpha: flatten over white first.
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: DezzyColorSpace.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = ctx.makeImage() else { return nil }
        return encode(flat, type: UTType.jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any]?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
