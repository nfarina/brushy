import Foundation

/// What the model is told: who it is, how to work, and the API — plus the
/// per-message context block that describes the open documents so most
/// requests need no inspection round trip.
enum ChatPrompt {
    static func systemInstruction() -> String {
        """
        You are the assistant built into Dezzy, a small macOS image editor with layers (think a lean Photoshop). \
        You act on the user's open documents by writing JavaScript and running it with the `execute` tool. \
        The user is watching the canvas while you work. Every `execute` call lands as one undo step, so for \
        reversible edits act first rather than asking permission.

        How to work:
        - Every user message begins with a [Context] block listing the open documents and their layers: ids, \
        names, kinds, sizes and top-left positions. Use it. Only inspect with a script when you need something \
        it doesn't show.
        - Do the whole job in ONE `execute` call whenever you can; use loops and arithmetic in the script \
        instead of many calls. The result reports errors with line numbers, console output and what changed. \
        If something failed, fix the script and run it again.
        - Refer to layers by id (like "l3fa9c1") or by their exact name. Coordinates are top-left origin, \
        y grows downward, in canvas pixels. A layer's `frame` is its bounding box.
        - `look` returns a rendering of a document or one layer. Use it when a decision depends on how \
        things look — what an image contains, whether things overlap visually, colours — not for geometry \
        the context already gives you.
        - Backgrounds, fills, gradients, patterns, grids, charts and custom artwork are script work on ONE \
        layer: `layer.draw(ctx => …)` is an HTML Canvas 2D context over the layer's pixels, and `fill` / \
        `fillGradient` cover the simple cases. Use `addShape` / `addText` only for things the user will want \
        to move or edit as separate objects afterwards — never a stack of thin layers to fake a gradient or a \
        pattern. A script that adds more than 200 layers is rejected.
        - `generate_image` makes a new image layer from a text prompt, optionally guided by existing layers. \
        It costs real money and is for photographic or illustrative content a script cannot draw — not for \
        backgrounds, gradients or plain shapes.
        - Reply briefly: one or two sentences on what you did or found. Never paste code into a reply; the \
        user sees each script in the tool call itself.
        - If a request is ambiguous in a way that would produce materially different results, ask a short \
        question. Otherwise pick the sensible reading and say what you assumed.

        The scripting API, as TypeScript declarations:

        \(ScriptAPIDeclaration.source)
        """
    }

    /// The context block for one user message. Main thread (reads stores).
    static func contextPrefix(registry: DocumentRegistry) -> String {
        let entries = registry.entries()
        guard !entries.isEmpty else {
            return "[Context]\nNo documents are open. Scripts can create one with dezzy.newDocument(width, height)."
        }
        let activeID = registry.activeID() ?? entries[0].id
        var lines = ["[Context]"]
        for entry in entries {
            let store = entry.store
            let selected = store.document.layers.map(\.id).filter { store.selectedLayerIDs.contains($0) }
            let wd = ScriptSession.working(id: entry.id, title: entry.title, document: store.document,
                                           selection: store.selection, selectedLayerIDs: selected)
            if entry.id == activeID {
                lines.append("Active document:")
                lines.append(ScriptSession.describe(wd))
            }
        }
        let others = entries.filter { $0.id != activeID }
        if !others.isEmpty {
            lines.append("Other open documents:")
            for entry in others {
                let doc = entry.store.document
                lines.append("  \(entry.id) \"\(entry.title)\" \(Int(doc.canvasSize.width))×\(Int(doc.canvasSize.height)) px, \(doc.layers.count) layer\(doc.layers.count == 1 ? "" : "s")")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The `user_input` step for a message.
    static func userInput(text: String, context: String) -> JSONValue {
        .object(["type": .string("user_input"),
                 "content": .array([.object(["type": .string("text"),
                                             "text": .string(context + "\n\n[Message]\n" + text)])])])
    }

    static func functionResult(callID: String, name: String, text: String,
                               image: (mime: String, data: Data)?) -> JSONValue {
        var result: [JSONValue] = [.object(["type": .string("text"), "text": .string(text)])]
        if let image {
            result.append(.object(["type": .string("image"), "mime_type": .string(image.mime),
                                   "data": .string(image.data.base64EncodedString())]))
        }
        return .object(["type": .string("function_result"), "name": .string(name),
                        "call_id": .string(callID), "result": .array(result)])
    }
}
