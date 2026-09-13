import AppKit
import Foundation

/// The single source of truth for text measurement and layout configuration —
/// shared by the committed rasterization (`VectorRasterizer.render(text:)`)
/// and the on-canvas inline editor, so what you see while editing is
/// glyph-identical to what commits.
///
/// Deliberately TextKit 1: the stack is built manually
/// (NSTextStorage → NSLayoutManager → NSTextContainer) and the editor is
/// created with `NSTextView(frame:textContainer:)`, which never instantiates
/// TextKit 2 (no downgrade poke, no compatibility-mode logging).
enum TextLayout {
    /// Margin baked into the rasterized image around the text bounds.
    static let padding: CGFloat = 4
    /// Point text never wraps: the container is effectively unbounded.
    static let containerSize = CGSize(width: 16384, height: 16384)

    /// The one place font fallback happens.
    static func font(for spec: TextSpec) -> NSFont {
        NSFont(name: spec.fontName, size: CGFloat(spec.fontSize))
            ?? .systemFont(ofSize: CGFloat(spec.fontSize))
    }

    static func attributes(for spec: TextSpec) -> [NSAttributedString.Key: Any] {
        [
            .font: font(for: spec),
            .foregroundColor: NSColor(cgColor: spec.color.cgColor) ?? .black,
        ]
    }

    /// A fresh TextKit 1 system configured with the shared layout settings.
    ///
    /// OWNERSHIP: the storage retains the layout manager retains the container
    /// — nothing retains the storage. The CALLER must keep `storage` alive for
    /// as long as layout runs, or the system silently lays out zero glyphs.
    static func makeTextSystem(for spec: TextSpec)
        -> (storage: NSTextStorage, layoutManager: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(string: spec.text, attributes: attributes(for: spec))
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        let container = NSTextContainer(size: containerSize)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        return (storage, layoutManager, container)
    }

    /// Laid-out size of the text (unpadded, in points).
    static func usedSize(_ layoutManager: NSLayoutManager,
                         _ container: NSTextContainer) -> CGSize {
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).size
    }

    static func measure(_ spec: TextSpec) -> CGSize {
        let (storage, layoutManager, container) = makeTextSystem(for: spec)
        return withExtendedLifetime(storage) {
            usedSize(layoutManager, container)
        }
    }

    /// Shared rounding: content size in pixels including padding — the editor
    /// box and the committed raster must agree on this exactly.
    static func paddedPixelSize(for used: CGSize) -> (width: Int, height: Int) {
        (max(1, Int(ceil(used.width) + padding * 2)),
         max(1, Int(ceil(used.height) + padding * 2)))
    }

    /// The inline editor's box size for a spec (padded, with a minimum width
    /// so an empty box stays clickable). Used by the coordinator's fallback
    /// paths and the overlay hairline.
    static func editorContentSize(for spec: TextSpec) -> CGSize {
        let (width, height) = paddedPixelSize(for: measure(spec))
        return CGSize(width: max(CGFloat(width), 12), height: CGFloat(height))
    }
}
