import Foundation

/// Names the open documents for scripts and models: `doc1`, `doc2`, … in
/// order of first sight, stable for the life of the app process (a model
/// copies "doc2" reliably; it mangles UUIDs). App-level, like the chat
/// sidebar that uses it. The three closures are the app's only coupling —
/// tests supply their own stores and never touch `NSDocumentController`.
final class DocumentRegistry {
    static let shared = DocumentRegistry()

    struct Entry {
        let id: String
        let store: DocumentStore
        let title: String
    }

    /// The open documents, frontmost first. The app wires this to
    /// `NSDocumentController`; tests hand over their stores.
    var enumerate: () -> [(store: DocumentStore, title: String)] = { [] }
    /// The document a script means by "the active document".
    var active: () -> DocumentStore? = { nil }
    /// Opens a real document for one a script created. Receives the document
    /// value and its reserved id; returns the store now holding it.
    var createDocument: (Document, String) -> DocumentStore? = { _, _ in nil }

    private final class WeakStore {
        weak var store: DocumentStore?
        init(_ store: DocumentStore) { self.store = store }
    }

    private var idsByStore: [ObjectIdentifier: String] = [:]
    private var storesByID: [String: WeakStore] = [:]
    private var nextNumber = 1

    /// Assigns (or recalls) the id for a store.
    func id(for store: DocumentStore) -> String {
        let key = ObjectIdentifier(store)
        if let id = idsByStore[key], storesByID[id]?.store === store { return id }
        let id = reserveID()
        bind(store, to: id)
        return id
    }

    /// Hands out the next id without a store, for a document a script is
    /// about to create; `bind` attaches the store once it exists.
    func reserveID() -> String {
        defer { nextNumber += 1 }
        return "doc\(nextNumber)"
    }

    func bind(_ store: DocumentStore, to id: String) {
        idsByStore[ObjectIdentifier(store)] = id
        storesByID[id] = WeakStore(store)
    }

    func store(for id: String) -> DocumentStore? {
        storesByID[id]?.store
    }

    /// Live documents with their ids, frontmost first.
    func entries() -> [Entry] {
        enumerate().map { Entry(id: id(for: $0.store), store: $0.store, title: $0.title) }
    }

    func activeID() -> String? {
        guard let store = active() else { return entries().first?.id }
        return id(for: store)
    }
}
