import CoreGraphics
import Foundation

/// Serialises a document for the scripting API — as JSON-shaped
/// dictionaries for the JavaScript side and as compact text for a model's
/// context. Both speak top-left coordinates (`ScriptGeometry`) and short ids.
///
/// Short ids: the first six hex digits of a layer's or group's UUID behind a
/// one-letter prefix (`l3fa9c1`, `g12ab34`). Deterministic from the UUID, so
/// they stay stable across turns and script runs without any registry; a
/// collision inside one document (roughly 1 in 16 million per pair) extends
/// the shorter id until it is unique.
enum ScriptState {
    static func shortID(_ uuid: UUID, prefix: String, length: Int = 6) -> String {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return prefix + String(hex.prefix(length))
    }

    /// Short id → UUID for every layer and group in the document.
    struct IDMap {
        private(set) var layers: [String: UUID] = [:]
        private(set) var groups: [String: UUID] = [:]
        private(set) var shortIDs: [UUID: String] = [:]

        init(_ document: Document) {
            var layers: [String: UUID] = [:]
            var groups: [String: UUID] = [:]
            var shortIDs: [UUID: String] = [:]
            Self.assign(document.layers.map(\.id), prefix: "l", into: &layers, shortIDs: &shortIDs)
            Self.assign(document.groups.map(\.id), prefix: "g", into: &groups, shortIDs: &shortIDs)
            self.layers = layers
            self.groups = groups
            self.shortIDs = shortIDs
        }

        private static func assign(_ ids: [UUID], prefix: String, into table: inout [String: UUID],
                                   shortIDs: inout [UUID: String]) {
            for id in ids {
                var length = 6
                var short = ScriptState.shortID(id, prefix: prefix, length: length)
                while table[short] != nil, length < 32 {
                    length += 2
                    short = ScriptState.shortID(id, prefix: prefix, length: length)
                }
                table[short] = id
                shortIDs[id] = short
            }
        }

        func short(_ id: UUID) -> String { shortIDs[id] ?? ScriptState.shortID(id, prefix: "?") }
    }

    // MARK: - JSON state

    static func rect(_ rect: CGRect) -> [String: Any] {
        ["x": round3(rect.minX), "y": round3(rect.minY),
         "width": round3(rect.width), "height": round3(rect.height)]
    }

    private static func round3(_ v: CGFloat) -> Double {
        (Double(v) * 1000).rounded() / 1000
    }

    static func layer(_ layer: Layer, index: Int, in document: Document, ids: IDMap) -> [String: Any] {
        let height = document.canvasSize.height
        var dict: [String: Any] = [
            "id": ids.short(layer.id),
            "name": layer.name,
            "kind": kindName(layer.kind),
            "index": index,
            "visible": layer.isVisible,
            "opacity": round3(CGFloat(layer.opacity)),
            "blendMode": ScriptGeometry.blendModeName(layer.blendMode),
            "clipped": layer.isClippedToBelow,
            "group": layer.groupID.map { ids.short($0) } as Any,
            "frame": rect(ScriptGeometry.topLeft(layer.canvasBounds, canvasHeight: height)),
            "rotation": ScriptGeometry.rotationDegreesClockwise(of: layer.transform),
            "sourceWidth": layer.source.width,
            "sourceHeight": layer.source.height,
            "hasMask": layer.mask != nil,
            "paintable": layer.isPaintable,
            "hasEffects": layer.effects.isActive,
        ]
        if let spec = layer.kind.textSpec {
            dict["text"] = ["text": spec.text, "fontName": spec.fontName,
                            "fontSize": spec.fontSize, "color": ScriptGeometry.css(spec.color)]
        }
        if let spec = layer.kind.shapeSpec {
            dict["shape"] = ["kind": spec.kind.rawValue,
                             "fill": spec.fill.map(ScriptGeometry.css) as Any,
                             "stroke": spec.stroke.map(ScriptGeometry.css) as Any,
                             "strokeWidth": spec.strokeWidth,
                             "strokeStyle": spec.strokeStyle.rawValue]
        }
        if let spec = layer.kind.adjustmentSpec {
            dict["adjustment"] = spec.displayName
        }
        return dict
    }

    static func kindName(_ kind: LayerKind) -> String {
        switch kind {
        case .raster: return "raster"
        case .text: return "text"
        case .shape: return "shape"
        case .adjustment: return "adjustment"
        }
    }

    static func group(_ group: LayerGroup, ids: IDMap) -> [String: Any] {
        ["id": ids.short(group.id),
         "name": group.name,
         "visible": group.isVisible,
         "opacity": round3(CGFloat(group.opacity)),
         "blendMode": group.blendMode.map(ScriptGeometry.blendModeName) as Any,
         "parent": group.parentID.map { ids.short($0) } as Any]
    }

    static func document(id: String, title: String, document: Document,
                         selection: SelectionState, selectedLayerIDs: [UUID],
                         ids: IDMap) -> [String: Any] {
        let height = document.canvasSize.height
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "width": Int(document.canvasSize.width),
            "height": Int(document.canvasSize.height),
            "layers": document.layers.enumerated().map { layer($1, index: $0, in: document, ids: ids) },
            "groups": document.groups.map { group($0, ids: ids) },
            "selectedLayers": selectedLayerIDs.compactMap { ids.shortIDs[$0] },
        ]
        if let path = selection.path {
            dict["selection"] = rect(ScriptGeometry.topLeft(path.boundingBoxOfPath, canvasHeight: height))
        } else {
            dict["selection"] = NSNull()
        }
        return dict
    }

    // MARK: - Compact text (for the model)

    /// One document as a few lines a model can read at a glance — top→bottom
    /// panel order with folder indentation, position and size, and only the
    /// flags that differ from the default.
    static func describe(id: String, title: String, document: Document,
                         selection: SelectionState, selectedLayerIDs: [UUID],
                         ids: IDMap) -> String {
        let height = document.canvasSize.height
        var lines: [String] = []
        lines.append("\(id) \"\(title)\" \(Int(document.canvasSize.width))×\(Int(document.canvasSize.height)) px, \(document.layers.count) layer\(document.layers.count == 1 ? "" : "s")")
        if document.layers.isEmpty {
            lines.append("  (no layers)")
        } else {
            lines.append("  Layers, top → bottom:")
            for row in document.panelRows() {
                let indent = String(repeating: "  ", count: row.depth + 1)
                switch row {
                case .group(let group, _):
                    var flags: [String] = []
                    if !group.isVisible { flags.append("hidden") }
                    if group.opacity < 1 { flags.append("\(Int((group.opacity * 100).rounded()))%") }
                    if let mode = group.blendMode { flags.append(ScriptGeometry.blendModeName(mode)) }
                    lines.append("\(indent)\(ids.short(group.id)) [group] \"\(group.name)\"" +
                                 (flags.isEmpty ? "" : " " + flags.joined(separator: " ")))
                case .layer(let layer, _):
                    let frame = ScriptGeometry.topLeft(layer.canvasBounds, canvasHeight: height)
                    var parts = ["\(indent)\(ids.short(layer.id)) \"\(layer.name)\"", kindName(layer.kind)]
                    if let spec = layer.kind.textSpec {
                        let text = spec.text.replacingOccurrences(of: "\n", with: "⏎")
                        parts.append("“\(text.count > 40 ? String(text.prefix(40)) + "…" : text)” \(Int(spec.fontSize))px \(spec.fontName)")
                    }
                    if let spec = layer.kind.shapeSpec { parts.append(spec.kind.rawValue) }
                    parts.append("\(fmt(frame.width))×\(fmt(frame.height)) @ (\(fmt(frame.minX)), \(fmt(frame.minY)))")
                    let rotation = ScriptGeometry.rotationDegreesClockwise(of: layer.transform)
                    if abs(rotation) >= 0.01 { parts.append("rotated \(fmt(CGFloat(rotation)))°") }
                    if !layer.isVisible { parts.append("hidden") }
                    if layer.opacity < 1 { parts.append("\(Int((layer.opacity * 100).rounded()))%") }
                    if layer.blendMode != .normal { parts.append(ScriptGeometry.blendModeName(layer.blendMode)) }
                    if layer.isClippedToBelow { parts.append("clipped") }
                    if layer.mask != nil { parts.append("masked") }
                    if layer.effects.isActive { parts.append("fx") }
                    lines.append(parts.joined(separator: " "))
                }
            }
        }
        if let path = selection.path {
            let r = ScriptGeometry.topLeft(path.boundingBoxOfPath, canvasHeight: height)
            lines.append("  Selection: \(fmt(r.width))×\(fmt(r.height)) @ (\(fmt(r.minX)), \(fmt(r.minY)))")
        }
        let selected = selectedLayerIDs.compactMap { ids.shortIDs[$0] }
        if !selected.isEmpty {
            lines.append("  Selected layers: \(selected.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ v: CGFloat) -> String {
        let rounded = (Double(v) * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}
