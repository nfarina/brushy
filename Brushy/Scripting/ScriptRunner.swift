import CoreGraphics
import Foundation

/// Main-thread orchestration around `ScriptHost`: snapshots the open
/// documents into a `ScriptSession`, runs the script on a background queue,
/// and commits whatever it touched — one `DocumentStore.commit` per document
/// (§6), named after the script's description so the History panel and the
/// Edit menu read "Undo AI: Arrange screenshots".
///
/// The user may keep editing while a script runs. A store whose document
/// moved on since the snapshot is never overwritten: the run is retried once
/// against fresh snapshots, then reported as a conflict.
final class ScriptRunner {
    struct DocumentChange: Equatable {
        let id: String
        let title: String
        /// "added "Title"; changed "Photo"" — what a model needs to verify.
        let summary: String
        /// The document after the script, in `ScriptState.describe` form.
        let after: String
    }

    struct Result {
        var outcome: ScriptHost.Outcome
        var changes: [DocumentChange] = []
        /// True when the documents changed underneath the script twice.
        var conflicted = false

        var succeeded: Bool { outcome.failure == nil && !conflicted }
    }

    static let actionPrefix = "AI: "

    let registry: DocumentRegistry
    let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.nfarina.brushy.script", qos: .userInitiated)

    init(registry: DocumentRegistry, timeout: TimeInterval = 20) {
        self.registry = registry
        self.timeout = timeout
    }

    /// Runs `code`, committing on success. `completion` lands on main.
    /// `images` are pre-registered for `doc.addImage(id)` — how a generated
    /// image reaches a document.
    func run(code: String, description: String, images: [String: CGImage] = [:],
             completion: @escaping (Result) -> Void) {
        run(code: code, description: description, images: images, attempt: 1, completion: completion)
    }

    private func run(code: String, description: String, images: [String: CGImage], attempt: Int,
                     completion: @escaping (Result) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let session = snapshot()
        for (id, image) in images { _ = session.registerImage(image, id: id) }
        let timeout = self.timeout
        queue.async {
            let outcome = ScriptHost.run(code: code, session: session, timeout: timeout)
            DispatchQueue.main.async {
                var result = Result(outcome: outcome)
                guard outcome.failure == nil else { return completion(result) }
                switch self.commit(session, description: description) {
                case .committed(let changes):
                    result.changes = changes
                    completion(result)
                case .conflict:
                    if attempt < 2 {
                        self.run(code: code, description: description, images: images,
                                 attempt: attempt + 1, completion: completion)
                    } else {
                        result.conflicted = true
                        completion(result)
                    }
                }
            }
        }
    }

    /// A session over the current state of every open document. In-flight
    /// gestures (Free Transform, a text edit) are landed first, so the base
    /// each copy starts from is the one `commit` will compare against.
    func snapshot() -> ScriptSession {
        dispatchPrecondition(condition: .onQueue(.main))
        let entries = registry.entries()
        let documents = entries.map { entry -> ScriptSession.WorkingDocument in
            entry.store.commitPendingSessions()
            let store = entry.store
            let selected = store.document.layers.map(\.id).filter { store.selectedLayerIDs.contains($0) }
            return ScriptSession.working(id: entry.id, title: entry.title, document: store.document,
                                         selection: store.selection, selectedLayerIDs: selected)
        }
        let registry = self.registry
        return ScriptSession(documents: documents, activeID: registry.activeID(),
                             reserveDocumentID: { registry.reserveID() })
    }

    enum CommitOutcome {
        case committed([DocumentChange])
        case conflict
    }

    /// Applies the session's touched documents to their stores. All-or-
    /// nothing across documents: the conflict check runs first for every
    /// document, so a stale second document never leaves the first half
    /// committed.
    func commit(_ session: ScriptSession, description: String) -> CommitOutcome {
        dispatchPrecondition(condition: .onQueue(.main))
        let touched = session.touchedDocuments
        var stores: [String: DocumentStore] = [:]
        for wd in touched where !wd.isNew {
            guard let store = registry.store(for: wd.id) else { continue }  // closed meanwhile
            store.commitPendingSessions()
            guard store.document == wd.base else { return .conflict }
            stores[wd.id] = store
        }
        var changes: [DocumentChange] = []
        let actionName = Self.actionPrefix + description
        for wd in touched {
            if wd.isNew {
                guard let store = registry.createDocument(wd.document, wd.id) else { continue }
                registry.bind(store, to: wd.id)
                if let last = wd.selectedLayerIDs.last { store.selectedLayerID = last }
                changes.append(DocumentChange(id: wd.id, title: wd.title,
                                              summary: ScriptSession.changeSummary(wd),
                                              after: ScriptSession.describe(wd)))
                continue
            }
            guard let store = stores[wd.id] else { continue }
            let live = Set(wd.document.layers.map(\.id))
            let selected = wd.selectedLayerIDs.filter { live.contains($0) }
            if selected.count > 1 {
                store.selectPanelRows(Set(selected))
            } else {
                store.selectedLayerID = selected.first
                    ?? (store.selectedLayerID.flatMap { live.contains($0) ? $0 : nil })
                    ?? wd.document.layers.last?.id
            }
            store.commit(actionName, document: wd.document, selection: wd.selection)
            changes.append(DocumentChange(id: wd.id, title: wd.title,
                                          summary: ScriptSession.changeSummary(wd),
                                          after: ScriptSession.describe(wd)))
        }
        return .committed(changes)
    }
}
