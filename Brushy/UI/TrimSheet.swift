import SwiftUI

/// Image > Trim… — Photoshop's Trim dialog: what counts as empty, and which
/// sides to trim it from. OK applies as a single undo step.
struct TrimSheet: View {
    @ObservedObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss

    @State private var basis = TrimBounds.Basis.transparentPixels
    @State private var sides = TrimBounds.Sides()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim")
                .font(.title3.weight(.semibold))

            Picker("Based On", selection: $basis) {
                ForEach(TrimBounds.Basis.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 6) {
                Text("Trim Away")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Toggle("Top", isOn: $sides.top)
                        Toggle("Left", isOn: $sides.left)
                    }
                    GridRow {
                        Toggle("Bottom", isOn: $sides.bottom)
                        Toggle("Right", isOn: $sides.right)
                    }
                }
                .padding(.leading, 12)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    store.trimBasis = basis
                    store.trimSides = sides
                    dismiss()
                    store.trim(basedOn: basis, sides: sides)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sides == TrimBounds.Sides(top: false, bottom: false,
                                                    left: false, right: false))
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            basis = store.trimBasis
            sides = store.trimSides
        }
    }
}
