import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenuBuilder.build()
        Self.configureDocumentRegistry()
    }

    /// The scripting layer's view of the open documents (`DocumentRegistry`)
    /// is the only place `NSDocumentController` meets the AI code.
    static func configureDocumentRegistry() {
        let registry = DocumentRegistry.shared
        registry.enumerate = {
            var seen = Set<ObjectIdentifier>()
            var ordered: [BrushyDocument] = []
            // Frontmost first, then anything AppKit's ordering left out.
            for document in NSApp.orderedDocuments.compactMap({ $0 as? BrushyDocument })
                + NSDocumentController.shared.documents.compactMap({ $0 as? BrushyDocument })
            where seen.insert(ObjectIdentifier(document)).inserted {
                ordered.append(document)
            }
            return ordered.map { ($0.store, $0.displayName ?? "Untitled") }
        }
        registry.active = { frontBrushyDocument()?.store }
        registry.createDocument = { document, _ in
            let created = ((try? NSDocumentController.shared
                .openUntitledDocumentAndDisplay(false)) as? BrushyDocument) ?? {
                let fallback = BrushyDocument()
                NSDocumentController.shared.addDocument(fallback)
                return fallback
            }()
            created.store.replaceDocument(document, actionName: DocumentStore.newDocumentActionName)
            created.store.canvasSizeChosenExplicitly = true
            created.makeWindowControllers()
            created.showWindows()
            return created.store
        }
    }

    /// View → Show AI Chat (⌘L). App-level like Settings: one flag every
    /// window's sidebar follows.
    @objc func toggleChatSidebar(_ sender: Any?) {
        MainActor.assumeIsolated { ChatStore.shared.isSidebarVisible.toggle() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleChatSidebar(_:)) {
            item.state = MainActor.assumeIsolated { ChatStore.shared.isSidebarVisible } ? .on : .off
        }
        return true
    }

    private var isDemoLaunch: Bool {
        CommandLine.arguments.contains("--demo")
            || ProcessInfo.processInfo.environment["BRUSHY_DEMO"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isDemoLaunch {
            DemoDocumentFactory.openDemoDocument()
        }
        DebugSnapshot.handleLaunchArgumentsIfNeeded()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !isDemoLaunch
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// General pane → "Reopen documents on launch". AppKit's own
    /// window restoration is the mechanism; the preference just gates it.
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        Defaults.value(Defaults.Keys.reopenDocumentsOnLaunch)
    }

    /// ⌘, — the standard macOS Settings item. It lives on the App menu and
    /// targets the *delegate*, not `BrushyDocument`, which is what makes
    /// it work with no document open: unlike almost every other command here,
    /// it never has to reach a document through the responder chain. The
    /// window is app-scoped and outlives every document window.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.showWindow()
    }

    /// File → New… (⌘N): asks for the canvas size first, like Photoshop's New
    /// Document dialog, then creates the untitled document at that size. Only
    /// this explicit path asks — launch, reopen-with-no-windows, and
    /// programmatic untitled documents (open-as-document, cross-document
    /// transfer) keep the silent default size.
    @objc func newDocumentAction(_ sender: Any?) {
        NewDocumentDialog.present { size in
            let document = Self.sizedUntitledDocument(size: size)
            document.makeWindowControllers()
            document.showWindows()
        }
    }

    /// Creates and sizes an untitled document WITHOUT showing it — callers
    /// make the window afterwards, so it never flashes at the default size.
    /// The controller path provides "Untitled n" numbering; the direct-init
    /// fallback covers environments without the app's document-type
    /// registration (tests — which also must stay windowless: a Metal-backed
    /// canvas window left in the test process measurably slows the
    /// performance test).
    static func sizedUntitledDocument(size: CGSize) -> BrushyDocument {
        let document = ((try? NSDocumentController.shared
            .openUntitledDocumentAndDisplay(false)) as? BrushyDocument) ?? {
            let fallback = BrushyDocument()
            NSDocumentController.shared.addDocument(fallback)
            return fallback
        }()
        var sized = Document(canvasSize: DocumentStore.clampedSize(size))
        // The dialog's document also starts with the blank "Layer 1" — and
        // keeps it on place/paste (explicit size ⇒ no pristine replacement).
        // Gated by the same General-pane preference as BrushyDocument.init.
        if Defaults.value(Defaults.Keys.startWithBlankLayer),
           let blank = DocumentStore.blankPaintLayer(canvasSize: sized.canvasSize,
                                                     name: "Layer 1") {
            sized.layers = [blank]
        }
        document.store.replaceDocument(sized,
                                       actionName: DocumentStore.newDocumentActionName)
        // A dialog-chosen size is authoritative: paste/place into this
        // document must scale content to fit, not adopt its frame.
        document.store.canvasSizeChosenExplicitly = true
        return document
    }

    /// Finder/dock open requests; nonexistent paths (e.g. stray launch
    /// arguments AppKit mistakes for documents) are dropped silently.
    func application(_ application: NSApplication, open urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        Self.handleOpen(urls: existing)
    }

    /// File → Open… (⌘O): `.brushy` documents and images each open as their
    /// own document (in a window tab), like Photoshop's Open.
    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        var types: [UTType] = [.image]
        if let brushy = UTType("com.nfarina.brushy.document") { types.insert(brushy, at: 0) }
        panel.allowedContentTypes = types
        panel.message = "Opens each file as its own document"
        panel.begin { response in
            guard response == .OK else { return }
            Self.handleOpen(urls: panel.urls)
        }
    }

    /// File → Place… (⇧⌘P) and File → Open as Layer… (⌥⌘O): one operation
    /// under two names — adds images to the current document as layers,
    /// arriving with Free Transform active. Falls back to a fresh untitled
    /// document when none is open, so the command is safe with zero windows.
    @objc func placeImagesAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Adds each image to the current document as a layer"
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let target = Self.frontBrushyDocument()
                ?? (try? NSDocumentController.shared
                    .openUntitledDocumentAndDisplay(true)) as? BrushyDocument
            target?.store.placeImages(from: panel.urls)
        }
    }

    /// Shared open routing (open panel and Finder/dock): every file becomes
    /// its own document. `.psd` files open as LAYERS(— see
    /// `PSDReader`), not as a flattened image, which is the whole point of
    /// reading them.
    static func handleOpen(urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "brushy" {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error {
                    NSApp.presentError(error)
                }
            }
        }
        for url in urls where url.pathExtension.lowercased() == "psd" {
            openPSDAsNewDocument(url)
        }
        for url in urls where !["brushy", "psd"].contains(url.pathExtension.lowercased()) {
            openImageAsNewDocument(url)
        }
    }

    /// Reads the PSD's layer stack into a fresh document. A file this reader
    /// can't take apart still opens — `PSDReader` falls back to the
    /// composite — so failures here are genuinely unreadable files, and they
    /// surface as an error rather than a silently empty window.
    private static func openPSDAsNewDocument(_ url: URL) {
        do {
            let parsed = try PSDReader.document(at: url)
            guard let target = documentForArrival() else { return }
            target.store.replaceDocument(parsed)
            // Photoshop opens a PSD as an untitled-but-named window; keeping
            // fileURL nil means ⌘S can't overwrite the .psd through the
            // .brushy serializer.
            target.displayName = url.deletingPathExtension().lastPathComponent
            target.windowControllers.first?.synchronizeWindowTitleWithDocumentName()
        } catch {
            NSApp.presentError(error)
        }
    }

    /// The document an opened file should land in: a pristine untitled window
    /// (e.g. the one created at launch) rather than leaving it orphaned
    /// behind the new tab, otherwise a fresh one.
    private static func documentForArrival() -> BrushyDocument? {
        if let front = frontBrushyDocument(),
           front.fileURL == nil, !front.isDocumentEdited,
           front.store.document.layers.isEmpty || front.store.isPristineBlankDocument {
            return front
        }
        return (try? NSDocumentController.shared
            .openUntitledDocumentAndDisplay(true)) as? BrushyDocument
    }

    private static func openImageAsNewDocument(_ url: URL) {
        guard let target = documentForArrival() else { return }
        target.store.placeImages(from: [url])
        target.displayName = url.deletingPathExtension().lastPathComponent
        target.windowControllers.first?.synchronizeWindowTitleWithDocumentName()
    }

    private static func frontBrushyDocument() -> BrushyDocument? {
        if let current = NSDocumentController.shared.currentDocument as? BrushyDocument {
            return current
        }
        return NSApp.orderedDocuments.compactMap { $0 as? BrushyDocument }.first
    }
}
