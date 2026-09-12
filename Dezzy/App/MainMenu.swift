import AppKit

/// The main menu, built in code (no nibs). Single-key tool shortcuts (V, M, L,
/// C, ⌫) are deliberately NOT menu key equivalents — bare-key equivalents
/// would swallow typing in text fields; the canvas handles them in keyDown.
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        let appName = "Dezzy"
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        // Settings… in its standard position: immediately after
        // About, behind a separator. AppDelegate owns it — not
        // DezzyDocument — so ⌘, works with zero documents open.
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: appName)

        // File
        let file = NSMenu(title: "File")
        // ⌘N asks for the document size first (Photoshop's New dialog).
        // AppDelegate owns it so it works with zero documents open; launch and
        // programmatic untitled documents keep the silent default size.
        file.addItem(withTitle: "New…", action: #selector(AppDelegate.newDocumentAction(_:)),
                     keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocumentAction(_:)),
                     keyEquivalent: "o")
        // Open as Layer and Place are the same operation under two names
        //: users reaching for ⌘O to add a layer find the layer path
        // right below Open, instead of a panel hint telling them they picked
        // the wrong command.
        let openAsLayer = file.addItem(withTitle: "Open as Layer…",
                                       action: #selector(AppDelegate.placeImagesAction(_:)),
                                       keyEquivalent: "o")
        openAsLayer.keyEquivalentModifierMask = [.command, .option]
        let place = file.addItem(withTitle: "Place…",
                                 action: #selector(AppDelegate.placeImagesAction(_:)),
                                 keyEquivalent: "P")
        place.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
                     keyEquivalent: "w")
        file.addItem(withTitle: "Save…", action: #selector(NSDocument.save(_:)),
                     keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…",
                                  action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift, .option]
        file.addItem(withTitle: "Revert to Saved",
                     action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(.separator())
        let export = file.addItem(withTitle: "Export…",
                                  action: #selector(DezzyDocument.exportFlattened(_:)),
                                  keyEquivalent: "S")
        export.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu: file, title: "File")

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        // Canvas clipboard. Cut/Copy/Paste use the standard NSText
        // selectors on purpose: while inline text editing has an NSTextView as
        // first responder it claims them, so text keeps its own clipboard;
        // otherwise they fall through the chain to DezzyDocument.
        edit.addItem(withTitle: "Cut", action: #selector(DezzyDocument.cut(_:)),
                     keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(DezzyDocument.copy(_:)),
                     keyEquivalent: "c")
        let copyMerged = edit.addItem(withTitle: "Copy Merged",
                                      action: #selector(DezzyDocument.copyMerged(_:)),
                                      keyEquivalent: "C")
        copyMerged.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Paste", action: #selector(DezzyDocument.paste(_:)),
                     keyEquivalent: "v")
        let pasteInto = edit.addItem(withTitle: "Paste Into",
                                     action: #selector(DezzyDocument.pasteInto(_:)),
                                     keyEquivalent: "v")
        pasteInto.keyEquivalentModifierMask = [.command, .option]
        // Select All lives in the Select menu (Photoshop layout), not here.
        edit.addItem(.separator())
        edit.addItem(withTitle: "Free Transform",
                     action: #selector(DezzyDocument.freeTransform(_:)), keyEquivalent: "t")
        edit.addItem(.separator())
        // Photoshop's Edit → Fill… (⇧F5). Quick fills stay on ⌥⌫/⌘⌫, handled
        // by the canvas so text fields keep their delete behaviour.
        let fill = edit.addItem(withTitle: "Fill…",
                                action: #selector(DezzyDocument.showFill(_:)),
                                keyEquivalent: String(UnicodeScalar(NSF5FunctionKey)!))
        fill.keyEquivalentModifierMask = [.shift, .function]
        main.addItem(submenu: edit, title: "Edit")

        // Image
        let image = NSMenu(title: "Image")
        let imageSize = image.addItem(withTitle: "Image Size…",
                                      action: #selector(DezzyDocument.showImageSize(_:)),
                                      keyEquivalent: "i")
        imageSize.keyEquivalentModifierMask = [.command, .option]
        let canvasSize = image.addItem(withTitle: "Canvas Size…",
                                       action: #selector(DezzyDocument.showCanvasSize(_:)),
                                       keyEquivalent: "c")
        canvasSize.keyEquivalentModifierMask = [.command, .option]
        image.addItem(.separator())
        // Image > Crop: crop to the selection's bounds. Photoshop ships it
        // without a shortcut; ⌘K is the common custom binding.
        image.addItem(withTitle: "Crop",
                      action: #selector(DezzyDocument.cropToSelection(_:)), keyEquivalent: "k")
        main.addItem(submenu: image, title: "Image")

        // Layer
        let layer = NSMenu(title: "Layer")
        let newPaint = layer.addItem(withTitle: "New Layer",
                                     action: #selector(DezzyDocument.newPaintLayer(_:)),
                                     keyEquivalent: "N")
        newPaint.keyEquivalentModifierMask = [.command, .shift]
        layer.addItem(.separator())
        // Photoshop's ⌘J / ⇧⌘J. ⌘J with nothing selected duplicates the
        // layer, which is what Photoshop does and what the old binding did.
        layer.addItem(withTitle: "Layer via Copy",
                      action: #selector(DezzyDocument.layerViaCopy(_:)), keyEquivalent: "j")
        let viaCut = layer.addItem(withTitle: "Layer via Cut",
                                   action: #selector(DezzyDocument.layerViaCut(_:)),
                                   keyEquivalent: "J")
        viaCut.keyEquivalentModifierMask = [.command, .shift]
        layer.addItem(withTitle: "Duplicate Layer",
                      action: #selector(DezzyDocument.duplicateLayer(_:)), keyEquivalent: "")
        // Dynamic submenu: populated by the frontmost document, which adopts
        // it as NSMenuDelegate during validation (the open-documents list
        // changes as tabs open and close). The parent's action exists so the
        // item validates — and greys out — through the responder chain.
        let duplicateTo = layer.addItem(
            withTitle: "Duplicate Layer to",
            action: #selector(DezzyDocument.duplicateLayerToDocument(_:)),
            keyEquivalent: "")
        duplicateTo.submenu = NSMenu(title: "Duplicate Layer to")
        // Layer ▸ New Adjustment Layer. Like the Layer Style items, each
        // carries its kind as representedObject so one selector covers all.
        let adjustments = NSMenu(title: "New Adjustment Layer")
        for kind in ["Levels", "Curves", "Hue/Saturation"] {
            let item = adjustments.addItem(withTitle: "\(kind)…",
                                           action: #selector(DezzyDocument.newAdjustmentLayer(_:)),
                                           keyEquivalent: "")
            item.representedObject = kind
        }
        let adjustmentItem = layer.addItem(withTitle: "New Adjustment Layer",
                                           action: #selector(DezzyDocument.newAdjustmentLayer(_:)),
                                           keyEquivalent: "")
        adjustmentItem.submenu = adjustments
        layer.addItem(withTitle: "Edit Adjustment…",
                      action: #selector(DezzyDocument.editAdjustment(_:)), keyEquivalent: "")
        layer.addItem(.separator())
        // Photoshop's Layer ▸ Rasterize: the way out of the never-paint rule
        // for photos, text and shapes.
        layer.addItem(withTitle: "Rasterize Layer",
                      action: #selector(DezzyDocument.rasterizeLayer(_:)), keyEquivalent: "")
        layer.addItem(withTitle: "Merge Down",
                      action: #selector(DezzyDocument.mergeDown(_:)), keyEquivalent: "e")
        layer.addItem(withTitle: "Delete Layer",
                      action: #selector(DezzyDocument.deleteLayer(_:)), keyEquivalent: "")
        layer.addItem(.separator())
        // Layer groups: ⌘G groups the selected layer (or
        // wraps the selected group), ⇧⌘G dissolves the selected group.
        layer.addItem(withTitle: "Group Layer",
                      action: #selector(DezzyDocument.groupLayer(_:)), keyEquivalent: "g")
        let ungroup = layer.addItem(withTitle: "Ungroup",
                                    action: #selector(DezzyDocument.ungroupLayer(_:)),
                                    keyEquivalent: "G")
        ungroup.keyEquivalentModifierMask = [.command, .shift]
        layer.addItem(.separator())
        // Align & Distribute. Both submenus carry their command's
        // raw value as representedObject — like the Layer Style items — so one
        // selector and one validation case cover each group. Same commands as
        // the Move tool's options bar, which is where they get used; these are
        // for discoverability and shortcut assignment.
        let align = NSMenu(title: "Align")
        for edge in AlignEdge.allCases {
            let item = align.addItem(withTitle: edge.displayName,
                                     action: #selector(DezzyDocument.alignLayers(_:)),
                                     keyEquivalent: "")
            item.representedObject = edge.rawValue
        }
        let alignItem = layer.addItem(withTitle: "Align",
                                      action: #selector(DezzyDocument.alignLayers(_:)),
                                      keyEquivalent: "")
        alignItem.submenu = align
        let distribute = NSMenu(title: "Distribute")
        for command in DistributeCommand.allCases {
            let item = distribute.addItem(withTitle: command.displayName,
                                          action: #selector(DezzyDocument.distributeLayers(_:)),
                                          keyEquivalent: "")
            item.representedObject = command.rawValue
        }
        let distributeItem = layer.addItem(withTitle: "Distribute",
                                           action: #selector(DezzyDocument.distributeLayers(_:)),
                                           keyEquivalent: "")
        distributeItem.submenu = distribute
        layer.addItem(.separator())
        layer.addItem(withTitle: "Flip Horizontal",
                      action: #selector(DezzyDocument.flipHorizontal(_:)), keyEquivalent: "")
        layer.addItem(withTitle: "Flip Vertical",
                      action: #selector(DezzyDocument.flipVertical(_:)), keyEquivalent: "")
        layer.addItem(withTitle: "Rotate 90° Left",
                      action: #selector(DezzyDocument.rotate90Left(_:)), keyEquivalent: "")
        layer.addItem(withTitle: "Rotate 90° Right",
                      action: #selector(DezzyDocument.rotate90Right(_:)), keyEquivalent: "")
        layer.addItem(.separator())
        // Layer Style: Photoshop's submenu — Blending
        // Options first, then one item per effect, then Clear.
        let style = NSMenu(title: "Layer Style")
        style.addItem(withTitle: "Blending Options…",
                      action: #selector(DezzyDocument.showLayerStyle(_:)),
                      keyEquivalent: "")
        style.addItem(.separator())
        for kind in LayerEffects.Kind.allCases {
            let item = style.addItem(withTitle: "\(kind.displayName)…",
                                     action: #selector(DezzyDocument.showLayerStyleEffect(_:)),
                                     keyEquivalent: "")
            item.representedObject = kind.rawValue
        }
        style.addItem(.separator())
        style.addItem(withTitle: "Clear Layer Style",
                      action: #selector(DezzyDocument.clearLayerStyle(_:)),
                      keyEquivalent: "")
        let styleItem = layer.addItem(withTitle: "Layer Style",
                                      action: #selector(DezzyDocument.showLayerStyle(_:)),
                                      keyEquivalent: "")
        styleItem.submenu = style
        layer.addItem(.separator())
        layer.addItem(withTitle: "Add Layer Mask",
                      action: #selector(DezzyDocument.addLayerMask(_:)), keyEquivalent: "")
        layer.addItem(withTitle: "Delete Layer Mask",
                      action: #selector(DezzyDocument.deleteLayerMask(_:)), keyEquivalent: "")
        layer.addItem(withTitle: "Enable/Disable Layer Mask",
                      action: #selector(DezzyDocument.toggleLayerMask(_:)), keyEquivalent: "")
        layer.addItem(.separator())
        // Title flips to "Release Clipping Mask" in validation when the
        // selected layer is already clipped (Photoshop's ⌥⌘G toggle).
        let clippingMask = layer.addItem(
            withTitle: "Create Clipping Mask",
            action: #selector(DezzyDocument.toggleClippingMask(_:)),
            keyEquivalent: "g")
        clippingMask.keyEquivalentModifierMask = [.command, .option]
        main.addItem(submenu: layer, title: "Layer")

        // Select (Photoshop layout: All / Deselect / Inverse | Subject | Modify | Transform)
        let select = NSMenu(title: "Select")
        // ⌘A uses the standard selectAll: selector on purpose — see
        // DezzyDocument.selectAll: a focused text view claims it first,
        // so text fields keep select-all-text.
        select.addItem(withTitle: "All",
                       action: #selector(DezzyDocument.selectAll(_:)), keyEquivalent: "a")
        select.addItem(withTitle: "Deselect",
                       action: #selector(DezzyDocument.deselect(_:)), keyEquivalent: "d")
        let inverse = select.addItem(withTitle: "Inverse",
                                     action: #selector(DezzyDocument.invertSelection(_:)),
                                     keyEquivalent: "I")
        inverse.keyEquivalentModifierMask = [.command, .shift]
        select.addItem(.separator())
        // No key equivalent, like Photoshop's Select > Subject.
        select.addItem(withTitle: "Select Subject",
                       action: #selector(DezzyDocument.selectSubject(_:)),
                       keyEquivalent: "")
        select.addItem(.separator())
        let modify = NSMenu(title: "Modify")
        modify.addItem(withTitle: "Grow…",
                       action: #selector(DezzyDocument.showGrowSelection(_:)),
                       keyEquivalent: "")
        modify.addItem(withTitle: "Contract…",
                       action: #selector(DezzyDocument.showContractSelection(_:)),
                       keyEquivalent: "")
        modify.addItem(withTitle: "Border…",
                       action: #selector(DezzyDocument.showBorderSelection(_:)),
                       keyEquivalent: "")
        select.addItem(submenu: modify, title: "Modify")
        select.addItem(.separator())
        // Photoshop has no menu item for this at all (it is the toolbar toggle
        // and Q); one here makes the mode discoverable and the key visible.
        select.addItem(withTitle: "Edit in Quick Mask Mode",
                       action: #selector(DezzyDocument.toggleQuickMask(_:)),
                       keyEquivalent: "")
        select.addItem(.separator())
        select.addItem(withTitle: "Transform Selection",
                       action: #selector(DezzyDocument.transformSelection(_:)),
                       keyEquivalent: "")
        main.addItem(submenu: select, title: "Select")

        // View
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Zoom In",
                     action: #selector(DezzyDocument.zoomIn(_:)), keyEquivalent: "=")
        view.addItem(withTitle: "Zoom Out",
                     action: #selector(DezzyDocument.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Fit on Screen",
                     action: #selector(DezzyDocument.zoomToFit(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Actual Size (100%)",
                     action: #selector(DezzyDocument.zoomToActualSize(_:)), keyEquivalent: "1")
        // Rulers, guides, grid, snapping. Checkmarks are refreshed
        // in DezzyDocument.validateUserInterfaceItem.
        view.addItem(.separator())
        view.addItem(withTitle: "Show Rulers",
                     action: #selector(DezzyDocument.toggleRulers(_:)), keyEquivalent: "r")
        view.addItem(withTitle: "Show Guides",
                     action: #selector(DezzyDocument.toggleGuides(_:)), keyEquivalent: ";")
        let lockGuides = view.addItem(withTitle: "Lock Guides",
                                      action: #selector(DezzyDocument.toggleLockGuides(_:)),
                                      keyEquivalent: ";")
        lockGuides.keyEquivalentModifierMask = [.command, .option]
        view.addItem(withTitle: "Clear Guides",
                     action: #selector(DezzyDocument.clearGuides(_:)), keyEquivalent: "")
        view.addItem(withTitle: "Show Grid",
                     action: #selector(DezzyDocument.toggleGrid(_:)), keyEquivalent: "'")
        // Photoshop's View ▸ Show ▸ Pixel Grid; draws only above 500% zoom.
        view.addItem(withTitle: "Show Pixel Grid",
                     action: #selector(DezzyDocument.togglePixelGrid(_:)), keyEquivalent: "")
        let snap = view.addItem(withTitle: "Snap",
                                action: #selector(DezzyDocument.toggleSnapping(_:)),
                                keyEquivalent: ";")
        snap.keyEquivalentModifierMask = [.command, .shift]
        // App-level, like Settings: the chat sidebar belongs to the app,
        // not a document, so the delegate handles it and the checkmark
        // refreshes in `AppDelegate.validateMenuItem`.
        view.addItem(.separator())
        view.addItem(withTitle: "Show AI Chat",
                     action: #selector(AppDelegate.toggleChatSidebar(_:)), keyEquivalent: "l")
        // No key equivalent on purpose: Tab as a menu shortcut would steal
        // focus traversal from every text field, so the canvas handles Tab
        // in keyDown and the title retitles in validateUserInterfaceItem.
        view.addItem(withTitle: "Hide Panels",
                     action: #selector(DezzyDocument.togglePanels(_:)), keyEquivalent: "")
        main.addItem(submenu: view, title: "View")

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize",
                       action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                       keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front",
                       action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: window, title: "Window")
        // NSApp is nil until the shared application exists, which is the case
        // when a test builds the menu to check its wiring. Nothing here needs
        // the app object except this hand-off, and instantiating
        // NSApplication.shared just to satisfy it is not free in-process.
        NSApp?.windowsMenu = window

        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
