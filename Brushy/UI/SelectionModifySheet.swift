import SwiftUI

/// Select > Modify > Grow… / Contract… / Border… parameter sheet — the
/// counterpart of Photoshop's Expand/Contract/Border dialogs. One pixel
/// field, constrained to the feather field's 1–250 px range; OK applies
/// the command as a single undo step.
struct SelectionModifySheet: View {
    @ObservedObject var store: DocumentStore
    let kind: DocumentStore.SelectionModifyKind
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Double = 0

    private var validRange: ClosedRange<Double> {
        Double(SelectionState.modifyRadiusRange.lowerBound)
            ... Double(SelectionState.modifyRadiusRange.upperBound)
    }

    private var title: String {
        switch kind {
        case .grow: return "Grow Selection"
        case .contract: return "Contract Selection"
        case .border: return "Border Selection"
        }
    }

    private var fieldLabel: String {
        switch kind {
        case .grow: return "Grow By"
        case .contract: return "Contract By"
        case .border: return "Width"
        }
    }

    private var defaultAmount: Double { kind == .border ? 4 : 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            HStack(spacing: 6) {
                Text(fieldLabel)
                TextField("", value: $amount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                Text("px").foregroundStyle(.secondary)
            }

            Text("\(Int(validRange.lowerBound))–\(Int(validRange.upperBound)) px, matching the feather range.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    let clamped = min(max(amount, validRange.lowerBound), validRange.upperBound)
                    store.selectionModifyAmounts[kind] = clamped
                    switch kind {
                    case .grow: store.growSelection(by: clamped)
                    case .contract: store.contractSelection(by: clamped)
                    case .border: store.borderSelection(width: clamped)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validRange.contains(amount))
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            amount = store.selectionModifyAmounts[kind] ?? defaultAmount
        }
    }
}
