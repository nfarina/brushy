import AppKit
import Security
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only self-snapshot (`--snapshot <path>`): renders the window chrome
/// via cacheDisplay and paints the live canvas composite into the canvas area
/// (Metal layers don't participate in cacheDisplay). Lets automated checks see
/// the real UI without Screen Recording permission.
enum DebugSnapshot {
    /// Configured via the BRUSHY_SNAPSHOT environment variable, not argv:
    /// AppKit treats absolute-path launch arguments as documents to open and
    /// blocks in a modal error when they don't exist.
    static func handleLaunchArgumentsIfNeeded() {
        guard let path = ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT"],
              !path.isEmpty else { return }
        // Nobody is there to click a keychain permission prompt — and an
        // ad-hoc-signed build gets one on its first key read after every
        // rebuild. Reads fail silently instead (the "add a key" hint shows).
        SecKeychainSetUserInteractionAllowed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            // BRUSHY_OPEN=<path> opens a file through the app's real
            // routing first (the PSD reader, in practice). An environment
            // variable rather than an argument for the usual reason: AppKit
            // treats absolute-path arguments as documents of its own and can
            // wedge in a modal error.
            if let path = ProcessInfo.processInfo.environment["BRUSHY_OPEN"], !path.isEmpty {
                AppDelegate.handleOpen(urls: [URL(fileURLWithPath: path)])
            }
            // Restored autosaved documents can coexist with the demo document;
            // snapshot the one that actually has content — richest first, so
            // an opened file wins over a leftover blank window.
            let documents = NSDocumentController.shared.documents
                .compactMap { $0 as? BrushyDocument }
            let document = documents.max { $0.store.document.layers.count
                                            < $1.store.document.layers.count }
                ?? documents.first
            guard let document, let window = document.windowControllers.first?.window else {
                exit(0)
            }
            window.makeKeyAndOrderFront(nil)
            applyDebugState(to: document.store)
            // BRUSHY_SNAPSHOT_STATE=settingswindow captures the REAL Settings
            // window (toolbar tabs and all) through the window server, which
            // cacheDisplay can't do — see `captureThroughWindowServer`.
            if ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_STATE"] == "settingswindow" {
                let pane = ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_PANE"]
                    .flatMap(SettingsView.Pane.init(rawValue:)) ?? .general
                SettingsWindowController.showWindow(pane: pane)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let settings = SettingsWindowController.currentWindow {
                        captureThroughWindowServer(settings, to: URL(fileURLWithPath: path))
                    }
                    exit(0)
                }
                return
            }
            // BRUSHY_SNAPSHOT_STATE=imagesizewindow: the Image Size dialog in a
            // real window of its own, captured the same way.
            if ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_STATE"] == "imagesizewindow" {
                let dialog = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 250),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                dialog.contentView = NSHostingView(rootView: ImageSizeSheet(store: document.store))
                dialog.center()
                dialog.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    captureThroughWindowServer(dialog, to: URL(fileURLWithPath: path))
                    exit(0)
                }
                return
            }
            embedDialogIfRequested(in: window, store: document.store)
            // Give SwiftUI a runloop pass to rebuild panels before capturing —
            // and let async store work (Select Subject's Vision request) land
            // first, up to a bounded wait.
            captureWhenSettled(window: window, store: document.store, path: path,
                               attemptsLeft: 24, sheetSettlePasses: 3)
        }
    }

    /// Captures once the store has no in-flight async work (the Select
    /// Subject in-progress hint doubles as the busy flag), polling every half
    /// second, bounded so a wedged request still produces a snapshot.
    /// `dialogSettlePasses` gives an embedded dialog (see
    /// `embedDialogIfRequested`) a beat to lay its SwiftUI content out.
    private static func captureWhenSettled(window: NSWindow, store: DocumentStore,
                                           path: String, attemptsLeft: Int,
                                           sheetSettlePasses dialogSettlePasses: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if store.brushHint != nil && attemptsLeft > 0 {
                return captureWhenSettled(window: window, store: store, path: path,
                                          attemptsLeft: attemptsLeft - 1,
                                          sheetSettlePasses: dialogSettlePasses)
            }
            if dialogSettlePasses > 0,
               store.colorPickerRequest != nil
                || store.adjustmentRequest != nil || isSettingsSnapshot {
                return captureWhenSettled(window: window, store: store, path: path,
                                          attemptsLeft: attemptsLeft,
                                          sheetSettlePasses: dialogSettlePasses - 1)
            }
            defer { exit(0) }
            if ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_DEBUG"] == "1" {
                print("DEBUG first responder: "
                      + (window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"))
            }
            window.contentView?.layoutSubtreeIfNeeded()
            // BRUSHY_SNAPSHOT_WINDOW=1: the whole window as composed, title
            // bar included (the title-bar accessory is only visible this way).
            if ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_WINDOW"] == "1" {
                captureThroughWindowServer(window, to: URL(fileURLWithPath: path))
                return
            }
            write(window: window, store: store, to: URL(fileURLWithPath: path))
        }
    }

    /// Sheets can't be snapshotted: a sheet's SwiftUI content lives in its own
    /// window and comes back from `cacheDisplay` (and from the PDF/print path)
    /// as bare control shapes with no text. The main window's hosting view
    /// caches fine, so for dialog states the same SwiftUI view is embedded in
    /// the window instead of presented — the pixels are the dialog's, even
    /// though the presentation isn't.
    private static func embedDialogIfRequested(in window: NSWindow, store: DocumentStore) {
        guard let content = window.contentView else { return }
        // The Settings window is a secondary window, so it can't be
        // snapshotted either — same embedding trick, same reason.
        let dialog: (view: AnyView, size: CGSize)?
        if isSettingsSnapshot {
            // BRUSHY_SNAPSHOT_PANE picks the pane (the tab strip is the
            // real window's toolbar and isn't part of this embedding).
            let pane = ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_PANE"]
                .flatMap(SettingsView.Pane.init(rawValue:)) ?? .general
            dialog = (AnyView(SettingsView(pane: pane)), SettingsView.preferredSize)
        } else if let request = store.adjustmentRequest {
            dialog = (AnyView(AdjustmentSheet(store: store, layerID: request.id)),
                      CGSize(width: 430, height: 400))
        } else if let target = store.colorPickerRequest {
            dialog = (AnyView(ColorPickerSheet(store: store, target: target)),
                      CGSize(width: 520, height: 300))
        } else {
            dialog = nil
        }
        guard let dialog else { return }
        let hosting = NSHostingView(rootView: dialog.view)
        hosting.frame = CGRect(x: ((content.bounds.width - dialog.size.width) / 2).rounded(),
                               y: ((content.bounds.height - dialog.size.height) / 2).rounded(),
                               width: dialog.size.width, height: dialog.size.height)
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hosting.layer?.borderColor = NSColor.black.withAlphaComponent(0.5).cgColor
        hosting.layer?.borderWidth = 1
        hosting.identifier = dialogIdentifier
        content.addSubview(hosting)
        content.layoutSubtreeIfNeeded()
    }

    private static let dialogIdentifier = NSUserInterfaceItemIdentifier("debugDialog")

    /// BRUSHY_SNAPSHOT_STATE=settings — see `embedDialogIfRequested`.
    private static var isSettingsSnapshot: Bool {
        ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_STATE"] == "settings"
    }

    /// BRUSHY_SNAPSHOT_STATE=transform|crop|selection puts the UI into an
    /// overlay-bearing state before capturing.
    private static func applyDebugState(to store: DocumentStore) {
        switch ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_STATE"] {
        case "transform":
            store.selectLayer(store.document.layers.last?.id)
            store.enterTransformMode()
        case "adjustment":
            var curves = AdjustmentSpec.Curves()
            curves.outputs = [0, 0.12, 0.55, 0.88, 1] // a gentle S
            store.addAdjustmentLayer(.curves(curves))
        case "colorpicker":
            store.foregroundColor = CGColor(srgbRed: 0.15, green: 0.45, blue: 0.85, alpha: 1)
            store.colorPickerRequest = .foreground
        case "pixelgrid":
            // 1200% on the canvas centre: past the pixel grid's 500% threshold.
            let center = CGPoint(x: store.document.canvasSize.width / 2,
                                 y: store.document.canvasSize.height / 2)
            store.viewport.setZoom(12, anchorView: store.viewport.toView(center))
        case "quickmask":
            // A rectangle taken into Quick Mask, then painted into: the
            // rubylith over the unselected area is what this state is for.
            // Canvas-relative, so it reads the same on any demo document.
            let rect = store.document.canvasRect
            store.combineSelection(CGPath(rect: rect.insetBy(dx: rect.width * 0.15,
                                                             dy: rect.height * 0.15),
                                          transform: nil), mode: .replace)
            store.enterQuickMask()
            store.activeTool = .brush
            store.brushSize = rect.width / 6
            store.brushHardness = 40
            store.brushOpacity = 100
            store.foregroundColor = CGColor(gray: 0, alpha: 1)
            store.beginBrushStroke(at: CGPoint(x: rect.width * 0.3, y: rect.height * 0.3),
                                   eraser: false)
            store.continueBrushStroke(to: CGPoint(x: rect.width * 0.6, y: rect.height * 0.6))
            store.endBrushStroke()
            // Soft-edged and half-opacity, the two things a path selection
            // cannot express and this channel can.
            store.brushHardness = 0
            store.brushOpacity = 50
            store.beginBrushStroke(at: CGPoint(x: rect.width * 0.75, y: rect.height * 0.35),
                                   eraser: false)
            store.continueBrushStroke(to: CGPoint(x: rect.width * 0.75, y: rect.height * 0.75))
            store.endBrushStroke()
        case "crop":
            store.activeTool = .crop
            if var session = store.cropSession {
                let r = store.document.canvasRect
                session.rect = r.insetBy(dx: r.width * 0.15, dy: r.height * 0.12)
                session.isAdjusting = true
                store.updateCropSession(session)
            }
        case "brush":
            store.addPaintLayer()
            store.activeTool = .brush
            store.foregroundColor = CGColor(srgbRed: 0.95, green: 0.1, blue: 0.15, alpha: 1)
            store.brushSize = 46
            store.brushHardness = 85
            store.brushOpacity = 100
            store.beginBrushStroke(at: CGPoint(x: 120, y: 420), eraser: false)
            for step in 0...60 {
                let x = 120.0 + Double(step) * 9
                let y = 420.0 + sin(Double(step) / 6) * 90
                store.continueBrushStroke(to: CGPoint(x: x, y: y))
            }
            store.endBrushStroke()
            // Soft half-opacity stroke crossing itself — the ceiling in action.
            store.brushHardness = 0
            store.brushOpacity = 50
            store.brushSize = 70
            store.beginBrushStroke(at: CGPoint(x: 180, y: 150), eraser: false)
            store.continueBrushStroke(to: CGPoint(x: 620, y: 150))
            store.continueBrushStroke(to: CGPoint(x: 400, y: 60))
            store.continueBrushStroke(to: CGPoint(x: 400, y: 260))
            store.endBrushStroke()
            // Eraser cut through the squiggle.
            store.activeTool = .eraser
            store.brushHardness = 100
            store.brushOpacity = 100
            store.brushSize = 34
            store.beginBrushStroke(at: CGPoint(x: 300, y: 520), eraser: true)
            store.continueBrushStroke(to: CGPoint(x: 480, y: 330))
            store.endBrushStroke()
        case "eyedropper":
            store.activeTool = .eyedropper
        case "panelshidden":
            // Tab: only the canvas.
            store.panelsHidden = true
        case "chat":
            // The AI sidebar with a seeded transcript: a user request, the
            // script that ran, and the reply.
            MainActor.assumeIsolated {
                ChatStore.shared.isSidebarVisible = true
                let session = ChatStore.shared.newChat()
                var chat = session.chat
                chat.title = "Arrange the screenshots"
                chat.messages = [
                    ChatMessage(role: .user, text: "Arrange the two layers side by side with a 24px gap and fit the canvas."),
                    ChatMessage(role: .tool, tool: ToolCallRecord(
                        name: ChatTools.executeName, description: "Arrange layers in a row and fit canvas",
                        code: "doc.arrange(doc.layers, { gap: 24, x: 0, y: 0 });\ndoc.fitCanvasToContent(0);",
                        status: .succeeded, result: "OK. doc1 \"Untitled\": canvas 800×600 → 1224×400; changed \"Photo\", \"Checker\"",
                        duration: 0.02)),
                    ChatMessage(role: .assistant, text: "Done — both layers sit in a row 24px apart and the canvas now hugs them."),
                ]
                session.load(chat)
                ChatStore.shared.activeChatID = chat.id
            }
        case "history":
            // a history with a redo tail — several named steps, then
            // a jump back so the dimmed rows ahead are visible.
            store.rightPanel = .history
            store.selectLayer(store.document.layers.last?.id)
            store.addPaintLayer()
            store.activeTool = .brush
            store.foregroundColor = CGColor(srgbRed: 0.95, green: 0.1, blue: 0.15, alpha: 1)
            store.brushSize = 46
            store.beginBrushStroke(at: CGPoint(x: 120, y: 420), eraser: false)
            store.continueBrushStroke(to: CGPoint(x: 520, y: 300))
            store.endBrushStroke()
            store.duplicateSelectedLayer()
            store.renameLayer(store.document.layers.last!.id, to: "Copy")
            store.flipSelectedLayer(vertical: false)
            store.selectAll()
            store.jumpToHistory(index: 3)
        case "vector":
            var text = TextSpec()
            text.text = "Brushy\nannotations"
            text.fontSize = 56
            text.fontName = "Helvetica Neue"
            text.color = ColorSpec(r: 1, g: 1, b: 1)
            store.insertTextLayer(text, topLeftAt: CGPoint(x: 60, y: 560))

            store.shapeStyle = ShapeSpec(kind: .rectangle,
                                         fill: ColorSpec(r: 1, g: 0.85, b: 0.1, a: 0.35),
                                         stroke: ColorSpec(r: 1, g: 0.85, b: 0.1),
                                         strokeWidth: 5)
            store.addShapeLayer(dragRect: CGRect(x: 430, y: 330, width: 240, height: 180),
                                lineFrom: nil, lineTo: nil)

            store.shapeStyle = ShapeSpec(kind: .ellipse,
                                         fill: nil,
                                         stroke: ColorSpec(r: 0.3, g: 1, b: 0.5),
                                         strokeWidth: 6)
            store.shapeStyle.strokeStyle = .dashed
            store.addShapeLayer(dragRect: CGRect(x: 120, y: 120, width: 200, height: 150),
                                lineFrom: nil, lineTo: nil)

            store.shapeStyle = ShapeSpec(kind: .line,
                                         fill: nil,
                                         stroke: ColorSpec(r: 1, g: 0.25, b: 0.2),
                                         strokeWidth: 6)
            store.shapeStyle.strokeStyle = .dotted
            store.shapeStyle.arrowStart = true
            store.shapeStyle.arrowEnd = true
            store.addShapeLayer(dragRect: .null,
                                lineFrom: CGPoint(x: 300, y: 200),
                                lineTo: CGPoint(x: 430, y: 400))
        case "textedit":
            var text = TextSpec()
            text.text = "Type here…"
            text.fontSize = 64
            text.fontName = "Helvetica Neue"
            text.color = ColorSpec(r: 1, g: 1, b: 1)
            store.insertTextLayer(text, topLeftAt: CGPoint(x: 150, y: 470))
            if var layer = store.document.layers.last {
                let center = layer.sourceRect.center.applying(layer.transform)
                layer.transform = layer.transform.concatenating(
                    CGAffineTransform(translationX: -center.x, y: -center.y)
                        .concatenating(CGAffineTransform(rotationAngle: 0.19))
                        .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                store.replaceDocument(store.document.replacingLayer(layer))
                store.beginTextSession(editing: store.document.layers.last!.id, caretAt: nil)
            }
        case "textedit0":
            var text = TextSpec()
            text.text = "Mt Hood"
            text.fontSize = 64
            text.fontName = "Helvetica Neue"
            store.insertTextLayer(text, topLeftAt: CGPoint(x: 150, y: 470))
            store.beginTextSession(editing: store.document.layers.last!.id, caretAt: nil)
        case "textnew":
            // The T-click flow: placeholder seeded selected + floating bar.
            store.activeTool = .text
            store.textStyle.fontSize = 64
            store.textStyle.fontName = "Helvetica Neue"
            store.beginTextSession(creatingAt: CGPoint(x: 170, y: 430))
        case "selection":
            store.activeTool = .marquee
            let r = store.document.canvasRect
            let rect = CGRect(x: r.width * 0.2, y: r.height * 0.25,
                              width: r.width * 0.35, height: r.height * 0.4)
            store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace)
            let ellipse = CGPath(ellipseIn: CGRect(x: r.width * 0.45, y: r.height * 0.4,
                                                   width: r.width * 0.3, height: r.height * 0.3),
                                 transform: nil)
            store.combineSelection(ellipse, mode: .add)
        case "guides":
            // rulers + grid + a few guides, move tool active.
            store.rulersVisible = true
            store.gridVisible = true
            store.guidesVisible = true
            let r = store.document.canvasRect
            var doc = store.document
            doc = doc.addingGuide(Guide(axis: .vertical, position: (r.width * 0.25).rounded()))
            doc = doc.addingGuide(Guide(axis: .vertical, position: (r.width * 0.75).rounded()))
            doc = doc.addingGuide(Guide(axis: .horizontal, position: (r.height * 0.5).rounded()))
            store.commitGuideDrag(doc, actionName: "Add Guide")
            store.activeTool = .move
        case "subject":
            // Owner-requested Select Subject: a clean synthetic subject (red
            // disc on an off-white card) exercises the full Vision → contour →
            // selection path in the real app; the bounded capture wait above
            // lets the async commit land, so the snapshot shows the resulting
            // marching ants hugging the disc.
            let r = store.document.canvasRect
            let disc = GeneratedImages.image(width: 360, height: 360,
                                             colorSpace: BrushyColorSpace.displayP3) { col, row in
                let d = hypot(Double(col) + 0.5 - 180, Double(row) + 0.5 - 150)
                return d <= 120 ? (204, 31, 31, 255) : (245, 245, 245, 255)
            }
            var subjectLayer = Layer(name: "Subject Disc", source: disc)
            subjectLayer.transform = CGAffineTransform(translationX: ((r.width - 360) / 2).rounded(),
                                                       y: ((r.height - 360) / 2).rounded())
            var doc = store.document
            doc.layers.append(subjectLayer)
            store.commit("Add Subject Disc", document: doc)
            store.selectLayer(subjectLayer.id)
            store.selectSubject()
        case "groups":
            // Layer groups: a folder with a clipped pair,
            // a nested folder inside a second one, the outer set to Multiply
            // at 80% (isolated), and the folder row selected so the panel
            // header shows the group controls (Pass Through popup + opacity).
            let r = store.document.canvasRect
            func card(_ name: String, r red: Int, g green: Int, b blue: Int,
                      w: Int, h: Int, at origin: CGPoint) -> Layer {
                let rgba = (UInt8(red), UInt8(green), UInt8(blue))
                let image = GeneratedImages.image(width: w, height: h,
                                                  colorSpace: BrushyColorSpace.displayP3) { _, _ in
                    (rgba.0, rgba.1, rgba.2, 255)
                }
                return Layer(name: name, source: image,
                             transform: CGAffineTransform(translationX: origin.x, y: origin.y))
            }
            var doc = store.document
            let pair = LayerGroup(name: "Badge")
            var art = LayerGroup(name: "Artwork")
            art.blendMode = .multiply
            art.opacity = 0.8
            let nested = LayerGroup(name: "Accents", parentID: art.id)
            let base = card("Disc", r: 226, g: 62, b: 54, w: 260, h: 260,
                            at: CGPoint(x: r.width * 0.16, y: r.height * 0.30))
            var clip = card("Sheen", r: 255, g: 236, b: 200, w: 320, h: 140,
                            at: CGPoint(x: r.width * 0.12, y: r.height * 0.42))
            clip.isClippedToBelow = true
            clip.opacity = 0.85
            var wash = card("Wash", r: 84, g: 130, b: 220, w: 420, h: 300,
                            at: CGPoint(x: r.width * 0.45, y: r.height * 0.28))
            wash.opacity = 0.9
            let accent = card("Accent", r: 255, g: 214, b: 79, w: 180, h: 90,
                              at: CGPoint(x: r.width * 0.55, y: r.height * 0.55))
            var grouped = [base, clip, wash, accent]
            grouped[0].groupID = pair.id
            grouped[1].groupID = pair.id
            grouped[2].groupID = art.id
            grouped[3].groupID = nested.id
            doc.layers.append(contentsOf: grouped)
            doc.groups = [pair, art, nested]
            store.commit("Build Groups", document: doc)
            store.selectGroup(art.id)
        case "effects", "layerstyle":
            // Layer effects: a styled card and a styled
            // headline, so the canvas shows shadow/stroke/overlay work and the
            // panel shows the fx badges. "layerstyle" additionally opens the
            // card's drop shadow in the effects panel.
            let r = store.document.canvasRect
            let card = GeneratedImages.image(width: 420, height: 260,
                                             colorSpace: BrushyColorSpace.displayP3) { _, _ in
                (238, 240, 244, 255)
            }
            var cardLayer = Layer(name: "Card", source: card,
                                  transform: CGAffineTransform(translationX: (r.width * 0.18).rounded(),
                                                               y: (r.height * 0.34).rounded()))
            var shadow = DropShadowEffect()
            shadow.distance = 14
            shadow.size = 22
            shadow.opacity = 0.5
            cardLayer.effects.dropShadow = shadow
            var stroke = StrokeEffect()
            stroke.size = 3
            stroke.color = EffectColor(red: 0.16, green: 0.18, blue: 0.24)
            cardLayer.effects.stroke = stroke

            var text = TextSpec()
            text.text = "Layer FX"
            text.fontSize = 92
            text.fontName = "Helvetica Neue"
            text.color = ColorSpec(r: 1, g: 1, b: 1)
            store.insertTextLayer(text, topLeftAt: CGPoint(x: r.width * 0.44, y: r.height * 0.72))

            var doc = store.document
            doc.layers.insert(cardLayer, at: max(0, doc.layers.count - 1))
            if var headline = doc.layers.last {
                var gradient = GradientOverlayEffect()
                gradient.startColor = EffectColor(red: 1, green: 0.72, blue: 0.2)
                gradient.endColor = EffectColor(red: 0.95, green: 0.2, blue: 0.45)
                headline.effects.gradientOverlay = gradient
                var glow = OuterGlowEffect()
                glow.size = 18
                glow.color = EffectColor(red: 1, green: 0.45, blue: 0.1)
                headline.effects.outerGlow = glow
                var headlineShadow = DropShadowEffect()
                headlineShadow.distance = 6
                headlineShadow.size = 8
                headline.effects.dropShadow = headlineShadow
                doc = doc.replacingLayer(headline)
            }
            store.commit("Styled Layers", document: doc)
            store.selectLayer(cardLayer.id)
            if ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_STATE"] == "layerstyle" {
                store.showLayerEffects(cardLayer.id, focus: .dropShadow)
            }
        case "align":
            // three unequal cards, all selected at once, with the
            // Move tool active — so the shot shows the multi-row panel
            // selection and the options bar's align/distribute controls.
            let r = store.document.canvasRect
            func card(_ name: String, r red: Int, g green: Int, b blue: Int,
                      w: Int, h: Int, at origin: CGPoint) -> Layer {
                let image = GeneratedImages.solid(width: w, height: h,
                                                  r: UInt8(red), g: UInt8(green), b: UInt8(blue),
                                                  colorSpace: BrushyColorSpace.displayP3)
                return Layer(name: name, source: image,
                             transform: CGAffineTransform(translationX: origin.x, y: origin.y))
            }
            var doc = store.document
            let cards = [card("Card A", r: 226, g: 62, b: 54, w: 220, h: 160,
                              at: CGPoint(x: r.width * 0.08, y: r.height * 0.55)),
                         card("Card B", r: 84, g: 130, b: 220, w: 320, h: 120,
                              at: CGPoint(x: r.width * 0.40, y: r.height * 0.32)),
                         card("Card C", r: 255, g: 214, b: 79, w: 140, h: 260,
                              at: CGPoint(x: r.width * 0.72, y: r.height * 0.12))]
            doc.layers.append(contentsOf: cards)
            store.commit("Add Cards", document: doc)
            store.activeTool = .move
            store.selectPanelRows(Set(cards.map(\.id)))
        case "selectiontransform":
            // a live Select > Transform Selection session — the ants
            // follow the transformed outline and the handle box rides along.
            let r = store.document.canvasRect
            let rect = CGRect(x: r.width * 0.22, y: r.height * 0.28,
                              width: r.width * 0.34, height: r.height * 0.36)
            store.combineSelection(CGPath(rect: rect, transform: nil), mode: .replace)
            store.enterSelectionTransformMode()
            let about = CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .rotated(by: 0.14)
                .scaledBy(x: 1.18, y: 1.18)
                .translatedBy(x: -rect.midX, y: -rect.midY)
            store.updateSelectionTransformSession(about.concatenating(
                CGAffineTransform(translationX: r.width * 0.06, y: -r.height * 0.03)))
        default:
            break
        }
    }

    /// The whole window including its title bar and toolbar: `cacheDisplay`
    /// on the theme frame (the content view's superview) rather than the
    /// content view. The Metal canvas still comes out blank, and
    /// `CGWindowListCreateImage` is no alternative — it returns white
    /// without Screen Recording permission, even for the app's own windows.
    static func captureThroughWindowServer(_ window: NSWindow, to url: URL) {
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let image = rep.cgImage,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                1, nil) else {
            NSLog("Brushy: window capture failed for \(window.title)")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func write(window: NSWindow, store: DocumentStore, to url: URL) {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)

        if let host = findCanvasHost(in: content) {
            // The canvas subviews' frame, not the host bounds: while rulers
            // are visible the composite must not paint over them,
            // and the overlay below shares this origin.
            let canvasFrame = host.overlay.frame
            let frame = host.convert(canvasFrame, to: content)
            let drawRect = content.isFlipped
                ? CGRect(x: frame.minX, y: content.bounds.height - frame.maxY,
                         width: frame.width, height: frame.height)
                : frame
            let scale = window.backingScaleFactor
            let pixelBounds = CGRect(x: 0, y: 0,
                                     width: canvasFrame.width * scale,
                                     height: canvasFrame.height * scale)
            let transform = store.viewport.viewTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            let image = RenderEngine.shared.displayImage(for: store.document,
                                                         viewTransform: transform,
                                                         viewPixelBounds: pixelBounds,
                                                         contentScale: scale,
                                                         stroke: store.strokePreview,
                                                         excludingLayer: store.textSession?.layerID,
                                                         quickMask: store.quickMask)
            if let cgImage = RenderEngine.shared.context.createCGImage(
                image, from: pixelBounds, format: .RGBA8,
                colorSpace: BrushyColorSpace.sRGB),
               let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                NSImage(cgImage: cgImage, size: drawRect.size).draw(in: drawRect)
                // The composite covered the cached overlay pixels; draw the
                // overlay (ants, transform box, crop UI, guides) back on top.
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: drawRect.minX, y: drawRect.minY)
                host.overlay.displayIgnoringOpacity(host.overlay.bounds, in: ctx)
                // Then the inline text editor, placed by recomputing the same
                // geometry the coordinator used — reading frame off a rotated
                // NSView is not reliable.
                if let session = store.textSession,
                   let wrapper = host.subviews.last, wrapper !== host.overlay,
                   wrapper.bounds.width > 0, wrapper.bounds.height > 0 {
                    let contentSize = TextLayout.editorContentSize(for: session.spec)
                    if ProcessInfo.processInfo.environment["BRUSHY_SNAPSHOT_DEBUG"] == "1" {
                        let textView = wrapper.subviews.first
                        let placementCheck = TextEditingGeometry.placement(
                            anchorTopLeft: session.anchorTopLeft,
                            rotation: session.rotation,
                            scaleX: session.scaleX, scaleY: session.scaleY,
                            contentSize: contentSize, viewport: store.viewport)
                        let corners = TextEditingGeometry.canvasCorners(
                            anchorTopLeft: session.anchorTopLeft,
                            rotation: session.rotation,
                            scaleX: session.scaleX, scaleY: session.scaleY,
                            contentSize: contentSize).map { store.viewport.toView($0) }
                        let tvInHost = textView.map { host.convert($0.bounds, from: $0) } ?? .zero
                        let wrapperInHost = host.convert(wrapper.bounds, from: wrapper)
                        let info = """
                        contentSize: \(contentSize)
                        placement.frame: \(placementCheck.frame)
                        wrapper.frame(set): \(wrapper.frame)
                        wrapper→host (AppKit): \(wrapperInHost)
                        textView→host (AppKit): \(tvInHost)
                        hairline corners (view): \(corners)
                        viewport: zoom \(store.viewport.zoom) origin \(store.viewport.origin)
                        """
                        try? info.write(toFile: url.path + ".debug.txt",
                                        atomically: true, encoding: .utf8)
                    }
                    let placement = TextEditingGeometry.placement(
                        anchorTopLeft: session.anchorTopLeft,
                        rotation: session.rotation,
                        scaleX: session.scaleX,
                        scaleY: session.scaleY,
                        contentSize: contentSize,
                        viewport: store.viewport)
                    // Draw the session's glyphs through the shared TextKit
                    // stack (rendering the flipped NSTextView through a
                    // custom CTM mis-draws its selection; on glass AppKit
                    // composites the real view natively).
                    let cg = ctx.cgContext
                    cg.saveGState()
                    cg.translateBy(x: placement.frame.midX, y: placement.frame.midY)
                    cg.rotate(by: placement.rotationDegrees * .pi / 180)
                    cg.scaleBy(x: placement.frame.width / placement.boundsSize.width,
                               y: placement.frame.height / placement.boundsSize.height)
                    cg.translateBy(x: -placement.boundsSize.width / 2,
                                   y: -placement.boundsSize.height / 2)
                    let (glyphStorage, layoutManager, container) =
                        TextLayout.makeTextSystem(for: session.spec)
                    withExtendedLifetime(glyphStorage) {
                        cg.translateBy(x: 0, y: placement.boundsSize.height)
                        cg.scaleBy(x: 1, y: -1)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                        let glyphs = layoutManager.glyphRange(for: container)
                        let origin = CGPoint(x: TextLayout.padding, y: TextLayout.padding)
                        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    cg.restoreGState()
                    _ = wrapper
                }
                // The task bar was in the cached chrome but the composite
                // painted over it — draw the live view back on top. Its frame
                // is host-relative; the context origin is the canvas frame.
                if store.textSession != nil, let bar = host.textTaskBar {
                    ctx.cgContext.saveGState()
                    ctx.cgContext.translateBy(x: bar.frame.minX - canvasFrame.minX,
                                              y: bar.frame.minY - canvasFrame.minY)
                    bar.displayIgnoringOpacity(bar.bounds, in: ctx)
                    ctx.cgContext.restoreGState()
                }
                ctx.cgContext.restoreGState()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // An embedded dialog sits over the canvas, so the composite above just
        // painted across it — draw it back on top, like the text task bar.
        if let dialog = content.subviews.first(where: { $0.identifier == dialogIdentifier }),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: dialog.frame.minX, y: dialog.frame.minY)
            dialog.displayIgnoringOpacity(dialog.bounds, in: ctx)
            ctx.cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
        }

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }

    private static func findCanvasHost(in view: NSView) -> CanvasHostView? {
        if let host = view as? CanvasHostView { return host }
        for subview in view.subviews {
            if let found = findCanvasHost(in: subview) { return found }
        }
        return nil
    }
}
