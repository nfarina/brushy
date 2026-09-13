import CoreGraphics
import Foundation

enum Tool: String, CaseIterable, Identifiable {
    case move
    case marquee
    case lasso
    case wand         // selects by colour; traced into a path (MagicWand)
    case crop
    case eyedropper   // samples the composite into the colour wells
    case brush
    case eraser
    case gradient     // mask ramps (two-photo blends) are the headline use
    case text
    case shape

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .move: return "Move"
        case .marquee: return "Rectangular Marquee"
        case .lasso: return "Lasso"
        case .wand: return "Magic Wand"
        case .crop: return "Crop"
        case .eyedropper: return "Eyedropper"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .gradient: return "Gradient"
        case .text: return "Text"
        case .shape: return "Shape"
        }
    }

    var shortcutKey: String {
        switch self {
        case .move: return "V"
        case .marquee: return "M"
        case .lasso: return "L"
        case .wand: return "W"
        case .crop: return "C"
        case .eyedropper: return "I"
        case .brush: return "B"
        case .eraser: return "E"
        case .gradient: return "G"
        case .text: return "T"
        case .shape: return "U"
        }
    }

    var systemImage: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .marquee: return "rectangle.dashed"
        case .lasso: return "lasso"
        case .wand: return "wand.and.stars"
        case .crop: return "crop"
        case .eyedropper: return "eyedropper"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .gradient: return "square.lefthalf.filled"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        }
    }

    var isBrushFamily: Bool { self == .brush || self == .eraser }
}

/// The 8 transform/crop handles. `unitPoint` is in the unit square of the
/// box being transformed (y-up).
enum TransformHandle: CaseIterable {
    case bottomLeft, bottomCenter, bottomRight
    case middleRight
    case topRight, topCenter, topLeft
    case middleLeft

    var unitPoint: CGPoint {
        switch self {
        case .bottomLeft: return CGPoint(x: 0, y: 0)
        case .bottomCenter: return CGPoint(x: 0.5, y: 0)
        case .bottomRight: return CGPoint(x: 1, y: 0)
        case .middleRight: return CGPoint(x: 1, y: 0.5)
        case .topRight: return CGPoint(x: 1, y: 1)
        case .topCenter: return CGPoint(x: 0.5, y: 1)
        case .topLeft: return CGPoint(x: 0, y: 1)
        case .middleLeft: return CGPoint(x: 0, y: 0.5)
        }
    }

    var isCorner: Bool {
        switch self {
        case .bottomLeft, .bottomRight, .topRight, .topLeft: return true
        default: return false
        }
    }

    var opposite: TransformHandle {
        switch self {
        case .bottomLeft: return .topRight
        case .bottomCenter: return .topCenter
        case .bottomRight: return .topLeft
        case .middleRight: return .middleLeft
        case .topRight: return .bottomLeft
        case .topCenter: return .bottomCenter
        case .topLeft: return .bottomRight
        case .middleLeft: return .middleRight
        }
    }

    var scalesX: Bool { self != .bottomCenter && self != .topCenter }
    var scalesY: Bool { self != .middleLeft && self != .middleRight }

    func localPoint(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unitPoint.x * rect.width,
                y: rect.minY + unitPoint.y * rect.height)
    }
}

/// Live Cmd+T state. The document is updated live for full-quality preview;
/// `baseDocument` restores on Esc, and commit pushes one undo step.
struct TransformSession {
    let layerID: UUID
    let baseDocument: Document
    let initialTransform: CGAffineTransform
    var currentTransform: CGAffineTransform
    let sourceRect: CGRect

    init(layer: Layer, baseDocument: Document) {
        self.layerID = layer.id
        self.baseDocument = baseDocument
        self.initialTransform = layer.transform
        self.currentTransform = layer.transform
        self.sourceRect = layer.sourceRect
    }

    var hasChanges: Bool { currentTransform != initialTransform }

    /// Box corners in canvas space (bottom-left, bottom-right, top-right, top-left).
    func canvasCorners(of transform: CGAffineTransform? = nil) -> [CGPoint] {
        let t = transform ?? currentTransform
        return sourceRect.corners.map { $0.applying(t) }
    }

    var canvasCenter: CGPoint { sourceRect.center.applying(currentTransform) }
}

/// Live Select > Transform Selection state: transform gestures applied to
/// the selection outline. Deliberately parallel to — not reusing —
/// `TransformSession`, which is bound to a `layerID` and live-updates the
/// document; here the document is never touched and only the committed
/// selection changes, as one undo step. `baseBounds` plays the role of
/// `sourceRect`, so all of `TransformMath` applies unchanged, with
/// `currentTransform` mapping the base path (canvas space) onto its
/// transformed position, starting at identity.
struct SelectionTransformSession {
    let basePath: CGPath
    let baseBounds: CGRect
    var currentTransform: CGAffineTransform = .identity

    init?(selection: SelectionState) {
        guard let path = selection.path, !path.boundingBoxOfPath.isEmpty else { return nil }
        self.basePath = path
        self.baseBounds = path.boundingBoxOfPath
    }

    var hasChanges: Bool { currentTransform != .identity }

    /// The live transformed selection outline, canvas space.
    var currentPath: CGPath {
        var transform = currentTransform
        return basePath.copy(using: &transform) ?? basePath
    }
}

/// Live crop-tool state. Committing calls `Document.cropped(to:)` — canvas
/// frame and layer translations only, never pixels.
struct CropSession: Equatable {
    var rect: CGRect
    /// True while a handle/move/draw drag is active — shows the thirds overlay.
    var isAdjusting = false
}
