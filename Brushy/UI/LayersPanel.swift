import SwiftUI

/// layers panel: topmost layer first, thumbnail + name + visibility eye +
/// mask thumbnail, drag reorder, blend-mode popup + integer opacity slider in
/// the header (Photoshop's layout), double-click rename, a visible focus ring
/// showing whether the layer or its mask is targeted, and an indented ↳ badge
/// on clipped rows (⌥-click a layer thumbnail — or use the context menu /
/// ⌥⌘G — to toggle clipping).
///
/// Layer groups: folder rows with a disclosure triangle
/// (state persists in the model), members indented by depth, the folder eye
/// cascading over the subtree, double-click rename, drag-reorder that moves
/// whole folders and re-parents by drop gap, and group-level opacity/blend
/// controls (Pass Through + the standard modes) when a folder row is
/// selected. Rows are the pure `Document.panelRows()` model.
struct LayersPanel: View {
    @ObservedObject var store: DocumentStore
    @State private var editingRowID: UUID?
    @State private var editingName = ""
    @FocusState private var nameFieldFocused: Bool

    private var displayRows: [Document.PanelRow] {
        store.panelRows
    }

    /// One UUID space covers both row kinds. The SET form is what
    /// gives ⇧-click range and ⌘-click toggle for free; the setter routes the
    /// result back through the store's group-vs-layer model
    /// (`selectPanelRows`). A selected group shows as its own row, not as its
    /// members' rows — selecting a folder selects it as a unit.
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: {
                    if let groupID = store.selectedGroupID { return [groupID] }
                    return store.selectedLayerIDs
                },
                set: { ids in store.selectPanelRows(ids) })
    }

    var body: some View {
        VStack(spacing: 0) {
            controlsRow
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            Divider()
            if store.document.layers.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Text("Place or drop an image (⇧⌘P),\nor start from a blank layer")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button("New Blank Layer") { store.addPaintLayer() }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                }
                Spacer()
            } else {
                // Native selection: custom whole-row tap gestures would swallow
                // the drag that starts List's row reordering.
                ScrollViewReader { proxy in
                    List(selection: selectionBinding) {
                        ForEach(displayRows) { panelRow in
                            rowView(for: panelRow)
                                .tag(panelRow.id)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
                        }
                        .onMove { offsets, destination in
                            store.reorderPanelRows(fromDisplayOffsets: offsets,
                                                   toDisplayOffset: destination)
                        }
                    }
                    .listStyle(.plain)
                    .onDeleteCommand {
                        if store.selectedGroupID != nil {
                            store.deleteSelectedGroup()
                        } else {
                            store.deleteSelectedLayer()
                        }
                    }
                    // New layers insert above the table viewport, which keeps
                    // its scroll anchor and would leave them hidden — follow
                    // the selection instead.
                    .onChange(of: store.selectedLayerID) { _, newValue in
                        if let newValue { proxy.scrollTo(newValue) }
                    }
                    .onChange(of: store.selectedGroupID) { _, newValue in
                        if let newValue { proxy.scrollTo(newValue) }
                    }
                }
            }
            Divider()
            bottomBar
        }
        .background(.background.opacity(0.4))
    }

    @ViewBuilder
    private func rowView(for panelRow: Document.PanelRow) -> some View {
        switch panelRow {
        case .layer(let layer, let depth):
            layerRow(for: layer, depth: depth)
        case .group(let group, let depth):
            groupRow(for: group, depth: depth)
        }
    }

    /// Blend-mode popup beside the opacity slider — Photoshop's panel-header
    /// layout. Both drive the selected layer OR the selected group; a blend
    /// change is one discrete commit, while opacity keeps its live-drag +
    /// commit-on-release pair. Groups get the extra "Pass Through" entry
    /// (their default); layers never see it.
    private var controlsRow: some View {
        let layer = store.selectedLayer
        let group = store.selectedGroup
        let opacity = Binding<Double>(
            get: { Double((group?.opacity ?? layer?.opacity ?? 1) * 100).rounded() },
            set: { newValue in
                if let group {
                    store.setLiveGroupOpacity(group.id, Float(newValue / 100))
                } else if let id = store.selectedLayerID {
                    store.setLiveOpacity(id, Float(newValue / 100))
                }
            })
        let layerBlendMode = Binding<BlendMode>(
            get: { layer?.blendMode ?? .normal },
            set: { newValue in
                if let id = store.selectedLayerID {
                    store.setLayerBlendMode(id, newValue)
                }
            })
        let groupBlendMode = Binding<BlendMode?>(
            get: { group?.blendMode },
            set: { newValue in
                if let group {
                    store.setGroupBlendMode(group.id, newValue)
                }
            })
        return HStack(spacing: 8) {
            if group != nil {
                Picker("Blend Mode", selection: groupBlendMode) {
                    Text("Pass Through").tag(BlendMode?.none)
                    ForEach(Array(BlendMode.uiGroups.enumerated()), id: \.offset) { _, uiGroup in
                        Divider()
                        ForEach(uiGroup, id: \.self) { mode in
                            Text(mode.displayName).tag(BlendMode?.some(mode))
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 116)
                .help("Group blend mode — Pass Through composites members as if ungrouped")
            } else {
                Picker("Blend Mode", selection: layerBlendMode) {
                    ForEach(Array(BlendMode.uiGroups.enumerated()), id: \.offset) { index, uiGroup in
                        if index > 0 { Divider() }
                        ForEach(uiGroup, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 116)
                .disabled(layer == nil)
                .help("Blend mode")
            }
            Slider(value: opacity, in: 0...100, step: 1) { editing in
                if !editing {
                    if store.selectedGroup != nil {
                        store.endGroupOpacityEdit()
                    } else {
                        store.endOpacityEdit()
                    }
                }
            }
            .disabled(layer == nil && group == nil)
            .help(group != nil ? "Group opacity" : "Opacity")
            Text("\(Int(opacity.wrappedValue))%")
                .font(.callout.monospacedDigit())
                .frame(width: 42, alignment: .trailing)
        }
    }

    // MARK: - Folder rows

    @ViewBuilder
    private func groupRow(for group: LayerGroup, depth: Int) -> some View {
        let dimmed = !store.document.ancestorsVisible(fromDirectGroup: group.parentID)
        HStack(spacing: 8) {
            Button {
                store.setGroupVisibility(group.id, !group.isVisible)
            } label: {
                Image(systemName: group.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(group.isVisible ? Color.primary : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help("Toggle group visibility (hides every member)")

            Button {
                store.toggleGroupExpanded(group.id)
            } label: {
                Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .help(group.isExpanded ? "Collapse group" : "Expand group")

            Image(systemName: "folder")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 34)

            if editingRowID == group.id {
                TextField("Group name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit { finishRename(rowID: group.id) }
                    .onExitCommand { editingRowID = nil }
            } else {
                Text(group.name)
                    .lineLimit(1)
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) {
                        editingRowID = group.id
                        editingName = group.name
                        nameFieldFocused = true
                    }
            }

            Text("\(Int((group.opacity * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .padding(.leading, CGFloat(depth) * 14)
        .opacity(dimmed ? 0.45 : 1)
        .contextMenu {
            Button("Duplicate Group") {
                store.selectGroup(group.id); store.duplicateSelectedGroup()
            }
            Button("Ungroup") {
                store.selectGroup(group.id); store.ungroupSelection()
            }
            Divider()
            Button("Delete Group", role: .destructive) {
                store.selectGroup(group.id); store.deleteSelectedGroup()
            }
        }
    }

    // MARK: - Smart vs pixel layers

    /// "Smart" in the Photoshop sense: the layer's pixels are not the truth —
    /// a photo's original bytes, a live text/shape spec, an adjustment that
    /// has no pixels at all. Editing one rasterizes it first.
    static func isSmart(_ layer: Layer) -> Bool {
        if case .raster = layer.kind { return !layer.isPaintable }
        return true
    }

    /// Photoshop badges smart objects on the thumbnail; same idea, one glyph
    /// per kind (and for an adjustment it doubles as the only clue, since its
    /// thumbnail is blank).
    static func smartBadge(for layer: Layer) -> String? {
        switch layer.kind {
        case .adjustment(let spec): return spec.systemImage
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .raster: return layer.isPaintable ? nil : "photo"
        }
    }

    // MARK: - Layer rows

    @ViewBuilder
    private func layerRow(for layer: Layer, depth: Int) -> some View {
        // The focus ring tracks the ANCHOR, not the whole multi-selection:
        // it says where the brush and the single-layer commands would land.
        let isSelected = store.selectedLayerID == layer.id
        let dimmed = !store.document.ancestorsVisible(fromDirectGroup: layer.groupID)
        HStack(spacing: 8) {
            Button {
                store.setLayerVisibility(layer.id, !layer.isVisible)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .help("Toggle layer visibility")

            if layer.isClippedToBelow {
                // Photoshop's clipped-row treatment: an indent plus a bent
                // arrow pointing down at the base layer beneath.
                Image(systemName: "arrow.turn.left.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .padding(.leading, 8)
                    .help("Clipped to the layer below")
            }

            // Layer thumbnail — click targets the layer (focus ring);
            // ⌥-click toggles the clipping mask (Photoshop's ⌥-click between
            // rows, adapted to this list).
            // A Button, not a tap gesture on an Image: a bare `onTapGesture`
            // is invisible to keyboard focus and to VoiceOver, which is how
            // targeting a layer, targeting its mask and opening Layer Style
            // all ended up unreachable without a mouse. `.plain` keeps the
            // appearance identical to the gesture version.
            Button {
                // ⌘-click loads the layer's pixels as a selection (Photoshop)
                // and leaves the current target alone.
                if NSEvent.modifierFlags.contains(.command) {
                    store.selectPixels(of: layer.id)
                    return
                }
                store.selectLayer(layer.id)
                if NSEvent.modifierFlags.contains(.option) {
                    store.toggleClippingMask(layer.id)
                } else {
                    store.maskTargeted = false
                }
            } label: {
                Image(nsImage: ThumbnailCache.shared.layerThumbnail(for: layer))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 34)
                    .background(Color.black.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(isSelected && !store.maskTargeted ? Color.accentColor : Color.white.opacity(0.15),
                                    lineWidth: isSelected && !store.maskTargeted ? 2 : 1))
                    .overlay(alignment: .bottomTrailing) {
                        if let badge = Self.smartBadge(for: layer) {
                            Image(systemName: badge)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                                .padding(1)
                        }
                    }
            }
            .buttonStyle(.plain)
            // Double-click rasterizes a smart layer (Photoshop's gesture for
            // opening one, put to the use this app has for it). Simultaneous,
            // so the button's own click still targets the layer first. The
            // NAME's double-click renames, which is why this lives here.
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if layer.kind.adjustmentSpec != nil {
                    // An adjustment has nothing to rasterize; open its editor.
                    store.selectLayer(layer.id)
                    store.requestAdjustmentEdit()
                } else if Self.isSmart(layer) {
                    store.rasterizeLayer(layer.id)
                    store.showToast("Rasterized “\(layer.name)”")
                }
            })
            .accessibilityLabel("Layer thumbnail, \(layer.name)")
            .accessibilityValue(isSelected && !store.maskTargeted ? "Targeted" : "Not targeted")
            .accessibilityHint("Targets the layer's pixels. Command-click selects them. "
                               + "Option-click clips it to the layer below. "
                               + "Double-click rasterizes a smart layer.")
            .help("Click to target layer · ⌥-click to clip to the layer below")

            if let mask = layer.mask {
                Button {
                    store.selectLayer(layer.id)
                    if NSEvent.modifierFlags.contains(.shift) {
                        store.toggleMaskEnabled(layer.id)
                    } else {
                        store.maskTargeted = true
                    }
                } label: {
                    Image(nsImage: ThumbnailCache.shared.maskThumbnail(for: mask))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.25))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isSelected && store.maskTargeted ? Color.accentColor : Color.white.opacity(0.15),
                                        lineWidth: isSelected && store.maskTargeted ? 2 : 1))
                        .overlay {
                            if !mask.isEnabled {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.red)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Layer mask, \(layer.name)")
                .accessibilityValue(
                    (mask.isEnabled ? "Enabled" : "Disabled")
                        + (isSelected && store.maskTargeted ? ", targeted" : ""))
                .accessibilityHint("Targets the mask for painting. Shift-click disables it.")
                .help("Click to target mask · Shift-click to disable")
            }

            if editingRowID == layer.id {
                TextField("Layer name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .onSubmit { finishRename(rowID: layer.id) }
                    .onExitCommand { editingRowID = nil }
            } else {
                Text(layer.name)
                    .lineLimit(1)
                    // Italic marks a layer whose pixels aren't its own to
                    // edit — a photo, live text or shape, an adjustment. The
                    // thumbnail carries a matching badge.
                    .font(Self.isSmart(layer) ? .callout.italic() : .callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(Self.isSmart(layer)
                          ? "Smart layer — editing its pixels rasterizes it first "
                            + "(double-click the thumbnail to do it now)"
                          : "Pixel layer")
                    .onTapGesture(count: 2) {
                        editingRowID = layer.id
                        editingName = layer.name
                        nameFieldFocused = true
                    }
            }

            if !layer.effects.isEmpty {
                effectsBadge(for: layer)
            }

            Text("\(Int((layer.opacity * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .padding(.leading, CGFloat(depth) * 14)
        .opacity(dimmed ? 0.45 : 1)
        .contextMenu {
            // Each item switches the effect on and opens it in the effects
            // panel below the list.
            Menu("Layer Style") {
                ForEach(LayerEffects.Kind.allCases) { kind in
                    Button(kind.displayName) {
                        store.showLayerEffects(layer.id, focus: kind)
                    }
                }
                Divider()
                Button("Clear Layer Style") { store.clearLayerStyle(layer.id) }
                    .disabled(layer.effects.isEmpty)
            }
            Divider()
            Button("Duplicate Layer") { store.selectLayer(layer.id); store.duplicateSelectedLayer() }
            Button("Merge Down") { store.selectLayer(layer.id); store.mergeDownSelectedLayer() }
            Divider()
            Button("Group Layer") { store.selectLayer(layer.id); store.groupSelection() }
            if layer.groupID != nil {
                Button("Ungroup") { store.selectLayer(layer.id); store.ungroupSelection() }
            }
            Divider()
            if layer.mask == nil {
                Button("Add Layer Mask") { store.selectLayer(layer.id); store.addLayerMask() }
            } else {
                Button("Delete Layer Mask") { store.selectLayer(layer.id); store.deleteLayerMask() }
                Button(layer.mask?.isEnabled == true ? "Disable Layer Mask" : "Enable Layer Mask") {
                    store.toggleMaskEnabled(layer.id)
                }
            }
            if (store.document.layerIndex(of: layer.id) ?? 0) > 0 {
                Divider()
                Button(layer.isClippedToBelow ? "Release Clipping Mask" : "Create Clipping Mask") {
                    store.toggleClippingMask(layer.id)
                }
            }
            Divider()
            Button("Delete Layer", role: .destructive) {
                store.selectLayer(layer.id); store.deleteSelectedLayer()
            }
        }
    }

    /// Photoshop's fx badge: present whenever the layer carries a style,
    /// dimmed while the master switch is off. Click shows the effects panel;
    /// the context menu opens one effect there or switches them all off.
    private func effectsBadge(for layer: Layer) -> some View {
        let active = layer.effects.isActive
        return Button {
            store.showLayerEffects(layer.id)
        } label: {
            Text("fx")
                .font(.caption.weight(.bold))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(active ? 0.12 : 0.05)))
        }
            .buttonStyle(.plain)
            .accessibilityLabel("Layer style, \(layer.name)")
            .accessibilityValue(active
                ? layer.effects.activeKinds.map(\.displayName).joined(separator: ", ")
                : "Off")
            .accessibilityHint("Shows the layer's effects below the layer list.")
            .contextMenu {
                ForEach(layer.effects.activeKinds) { kind in
                    Button("Edit \(kind.displayName)") {
                        store.showLayerEffects(layer.id, focus: kind)
                    }
                }
                if !layer.effects.activeKinds.isEmpty { Divider() }
                Button(layer.effects.isEnabled ? "Disable Effects" : "Enable Effects") {
                    store.toggleLayerEffectsEnabled(layer.id)
                }
                Button("Clear Layer Style", role: .destructive) {
                    store.clearLayerStyle(layer.id)
                }
            }
            .help(active
                  ? "Layer effects: \(layer.effects.activeKinds.map(\.displayName).joined(separator: ", ")) — click to edit"
                  : "Layer effects are switched off — click to edit")
    }

    private func finishRename(rowID: UUID) {
        if store.document.group(withID: rowID) != nil {
            store.renameGroup(rowID, to: editingName)
        } else {
            store.renameLayer(rowID, to: editingName)
        }
        editingRowID = nil
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button {
                store.addPaintLayer()
            } label: {
                Image(systemName: "plus.square")
            }
            .buttonStyle(.plain)
            .help("New blank layer (⇧⌘N)")

            Button {
                store.addLayerMask()
            } label: {
                Image(systemName: "circle.rectangle.filled.pattern.diagonalline")
            }
            .buttonStyle(.plain)
            .disabled(store.selectedLayer == nil || store.selectedLayer?.mask != nil)
            .help("Add layer mask (from selection)")

            Button {
                store.groupSelection()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .disabled(!store.canGroupSelection)
            .help("Group layer (⌘G)")

            Button {
                if store.selectedGroupID != nil {
                    store.duplicateSelectedGroup()
                } else {
                    store.duplicateSelectedLayer()
                }
            } label: {
                Image(systemName: "square.on.square")
            }
            .buttonStyle(.plain)
            .disabled(store.selectedLayer == nil && store.selectedGroup == nil)
            .help("Duplicate selected layer or group (⌘J)")

            Spacer()

            Button {
                if store.selectedGroupID != nil {
                    store.deleteSelectedGroup()
                } else {
                    store.deleteSelectedLayer()
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(store.selectedLayer == nil && store.selectedGroup == nil)
            .help("Delete layer or group")
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
