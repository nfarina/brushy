# AGENTS.md — Dezzy

Architectural invariants and conventions for this repo, so task prompts don't
have to carry them.

Verified against source at time of writing. Symbol names are reliable; line
numbers may drift.

---

## Project

Dezzy is a native macOS 14+ image editor: Swift + Core Image + an
AppKit canvas + SwiftUI chrome, no nibs, no third-party dependencies.
Xcode project at `Dezzy.xcodeproj`.

```bash
# Build (use Release — Debug runs the brush engine's CPU paths ~10× slower)
xcodebuild -project Dezzy.xcodeproj -scheme Dezzy -configuration Release build

# Test
xcodebuild -project Dezzy.xcodeproj -scheme Dezzy test

# Run the demo composite
DEZZY_DEMO=1 open ~/Applications/Dezzy.app
```

`README.md` covers the feature set, the build/install dance, and the headless
snapshot environment variables in more detail.

Code comments cite design sections as `§N` (§2 model, §3 render, §4
canvas/navigation, §5 selection/paint, §6 undo, §7 colour, §8 file format, §9
tests); the README's Architecture notes carry the same legend. Keep that
convention in new comments, and cite the relevant § when you touch behaviour it
governs.

## Layout

```
Dezzy/
  App/      main.swift, AppDelegate.swift, MainMenu.swift, DemoDocument.swift, DebugSnapshot.swift
  Doc/      DezzyDocument.swift (NSDocument), DocumentSerialization.swift,
            PSDWriter.swift, PSDReader.swift, PSDFormat.swift, PSDDescriptor.swift, PSDEffects.swift
  Model/    Document.swift, DocumentOps.swift, LayerEffects.swift, Selection.swift,
            Geometry.swift, VectorContent.swift
  Render/   RenderEngine.swift, LayerEffectRenderer.swift, MaskFactory.swift, ImageImporter.swift,
            Exporter.swift, VectorRasterizer.swift, TextLayout.swift, ColorSpaces.swift,
            GeneratedImages.swift
  Store/    DocumentStore.swift          ← per-window state + undo history
  Scripting/ ScriptSession.swift (JSON op interpreter over Document values), ScriptPrelude.swift (JS API),
             ScriptAPIDeclaration.swift (.d.ts the model reads), ScriptHost.swift (JavaScriptCore + watchdog),
             ScriptRunner.swift (snapshot → run off-main → commit), DocumentRegistry.swift (doc1/doc2 ids)
  AI/       GeminiClient.swift, ChatSession.swift (tool loop), ChatTools.swift (execute/look/generate_image),
            ChatStore.swift, ChatPrompt.swift, Keychain.swift
  UI/Chat/  ChatSidebar.swift
  UI/       RootView.swift, LayersPanel.swift, ToolViews.swift, *Sheet.swift, Thumbnails.swift
  UI/Canvas/ CanvasHostView.swift (events), CanvasController.swift (tool logic),
             CanvasMetalView.swift, CanvasOverlayView.swift (vector overlay),
             Tool.swift, TransformMath.swift, SmartGuides.swift, Viewport.swift,
             BrushEngine.swift, Cursors.swift, TextEditing*.swift
DezzyTests/
```

`Store/DocumentStore.swift`, `UI/Canvas/CanvasController.swift` and
`Render/RenderEngine.swift` are the three largest and most central files; most
behaviour changes land in one of them.

## Invariants — violating these breaks undo, colour, or non-destructiveness

**1. `Document` is a value type and every operation is a pure
`Document -> Document` function.** Those functions live in
`Model/DocumentOps.swift` as an `extension Document` (`cropped(to:)`,
`scaled(to:)`, `replacingLayer(_:)`, `removingLayer(id:)`, …). New document
operations go there, not inline in the store or the UI. This is what makes
undo an array index.

**2. All history goes through `DocumentStore.commit(_:document:selection:)`.**
It pushes exactly one snapshot (`document` + `selection` + `selectedLayerID`),
caps history at 100, registers with `NSUndoManager` and sets the action name
that appears in the Edit menu. One user-visible operation = one `commit` call.
Mid-gesture live updates use `setLiveDocument(_:)` /
`setLiveLayerTransform(_:_:)`, which deliberately do **not** touch history.

**3. Call `store.commitPendingSessions()` first in any operation that changes
the document.** It lands an in-flight Free Transform and an in-flight text
session. Every existing mutating store method does this; follow the pattern.

**4. `Layer.source` is `let`.** Changing a layer's pixels means constructing a
new `Layer` with a **fresh `sourceID`** — see `DocumentStore.endBrushStroke()`
and `fillSelection(using:)` for the canonical pattern. Reusing the `sourceID`
will make the `.dezzy` serializer serve stale cached PNG bytes
(`DocumentSerializer` caches keyed on `sourceID`).

**5. Imported photos are never painted.** `Layer.isPaintable` is false for
imported images; destructive-looking operations route to a mask instead. The
routing logic to mirror is `DocumentStore.resolveStrokeTarget(eraser:)` and
`resolveFillTarget()`. Any new "destructive" op (e.g. Cut) must follow the same
routing.

**5b. A selection is a path that MAY carry a coverage channel.**
`SelectionState.path` is the geometry; `SelectionState.alpha` (a canvas-space
8-bit buffer, row 0 at top) appears only when the selection started life as
pixels — Quick Mask, or ⌘-clicking a layer to load its alpha. **When `alpha`
is present it IS the coverage and the path is only its traced 50% contour**;
never multiply the two, or the outer half of every soft edge disappears.
Read coverage through `MaskFactory` / `SelectionState.coverageTexture(over:)`
rather than rasterising the path yourself. A selection is also a stencil for
PAINT: strokes multiply by it at emission (`BrushStroke.selectionClip`), the
same way fills and gradients clip to it. Anything that reshapes the path
(booleans, Select ▸ Modify, a Transform Selection that is not a whole-pixel
translation) drops the channel; `DocumentStore.commitSelection(_:_:)` is what
tells the user it did.

**6. Coordinate spaces.**
- *Canvas space*: origin bottom-left, **y-up**, 1 point = 1 exported pixel.
  All model geometry (transforms, selection paths, crop rects) lives here.
- *View space*: the canvas `NSView`'s coordinates, also **y-up**
  (`CanvasHostView` is non-flipped) — differs from canvas space only by zoom
  and pan. Convert with `Viewport.toView(_:)` / `fromView(_:)`.
- *Source space*: a layer's own pixel grid; `layer.transform` maps source →
  canvas. Use `layer.transform.inverted()` to go the other way (guard with
  `.isInvertible` first).
- **Mask buffers are row-0-at-top**, i.e. flipped relative to canvas y-up. See
  `MaskTexture` docs and `MaskFactory.maskTexture(for:selection:featherCanvasPx:)`.
  This is the single most common place to introduce a vertical-flip bug.

**7. Layer effects are canvas-space and never touch the layer's pixels.**
`Layer.effects` (`LayerEffects`) renders in `LayerEffectRenderer` from the
layer's own coverage; sizes/distances are canvas points, so they are
independent of the layer's transform. Two rules that are easy to break:
a layer whose style is empty or switched off (`LayerEffects.isActive` false)
MUST take the pre-effects graph unchanged — the golden references and the §3
budget depend on it — and anything baking a layer down (merge, clipboard,
export bounds) must use `styledCanvasBounds`, not `canvasBounds`, or the
style gets cropped at the layer's edge.

**8. Colour.** Working space is linear Display P3, composited in linear light.
Sources keep their original bytes tagged with their own profile; conversion
happens in float at render time. Anything entering the app from outside must go
through `ImageImporter.normalize(_:orientation:)`. UI colour wells
(`store.foregroundColor` / `backgroundColor`) hold **sRGB** `CGColor`s — see
`ToolOptionsBar.colorBinding(_:)`.

## Conventions

### Adding a menu command

1. Add an `@objc func` to `DezzyDocument` (`Doc/DezzyDocument.swift`)
   that forwards to a `DocumentStore` method. The document is in the responder
   chain; the store holds the state.
2. Add the item in `MainMenuBuilder.build()` (`App/MainMenu.swift`) — the menu
   is built in code, no nibs.
3. Add a case to `DezzyDocument.validateUserInterfaceItem(_:)` so it
   enables/disables correctly. **Do not skip this** — an unvalidated selector
   falls through to `super` and behaves unpredictably.
4. If the command must be unavailable while type is being edited in place, add
   the selector to `DezzyDocument.actionsDisabledDuringTextEditing`.

**Bare-key shortcuts are not menu key equivalents.** Single keys (V, M, L, C,
B, E, T, U, X, D, `[`, `]`, ⌫) are handled in `CanvasHostView.keyDown(with:)`
by keyCode / `charactersIgnoringModifiers`, deliberately, so text fields keep
their normal typing behaviour. Follow that pattern for new single-key
shortcuts; use menu key equivalents only for modifier combinations.

### Adding a tool

`Tool` is an enum in `UI/Canvas/Tool.swift`. Adding a case forces exhaustive
switches to be updated — the compiler will point you at every one. Expect to
touch:

- `Tool.displayName` / `shortcutKey` / `systemImage` (`Tool.swift`)
- `CanvasController.mouseDown(at:modifiers:clickCount:)` — the tool switch
- `CanvasController.cursor(at:)` — the cursor for the tool
- `ToolOptionsBar.body` — the options-bar switch (`UI/ToolViews.swift`)
- `CanvasHostView.keyDown` — the single-key shortcut
- `CanvasOverlayView.draw(_:)` — only if the tool needs an overlay

`ToolStrip` iterates `Tool.allCases`, so the palette button appears
automatically.

### Overlay drawing

`CanvasOverlayView` is a transparent `NSView` above the Metal composite;
`hitTest(_:)` returns `nil`, so it never receives events — all input routing is
in `CanvasHostView` → `CanvasController`. It redraws on every store change
(cheap vector work); the Metal composite re-renders only when `renderVersion`,
the viewport, the stroke preview, or the text-session exclusion changes.

### Keychain reads are lazy and never happen in tests

`APIKeys.gemini` hits the keychain. An ad-hoc-signed build gets a permission
prompt on its first read after every rebuild, and under `xcodebuild test`
nobody clicks it — the run hangs. So nothing reads the key at init:
`ChatStore.hasGeminiKey` refreshes when a conversation appears and on
`APIKeys.didChange`; tests stub `ChatStore.keyLookup`; snapshot runs call
`SecKeychainSetUserInteractionAllowed(false)`.

### Extending the scripting API (what the AI can do)

One capability = three edits, kept in step: an op in `ScriptSession.perform`
(pure `Document` ops from `Model/`, top-left coordinates flipped through
`ScriptGeometry`), a method in `ScriptPrelude` (the JavaScript side), and its
declaration in `ScriptAPIDeclaration` (the model's only documentation).
Pixel drawing is the exception: `layer.draw(ctx => …)` records a Canvas 2D
subset in JavaScript (`DrawingContext` in the prelude) and replays it in
`ScriptDrawing` — extend the command set in both places, and document it on
`DrawingContext` in the declaration.
`ScriptHostTests.testDeclarationMentionsEveryPreludeMethod` fails when the
`.d.ts` lags the prelude. Every op must leave the document invariants
(group contiguity, clipping normalisation, fresh `sourceID` for new pixels)
intact — the session never touches a store; `ScriptRunner.commit` is the one
place scripts reach `DocumentStore.commit`, once per touched document.
Scripts run off-main against `Document` value copies; anything they call
must be safe there (rasterisers and `MaskFactory` are).

### Tests

XCTest in `DezzyTests/`. The pattern worth preserving: **pure geometry is
extracted and unit-tested separately from the controller** — see
`TransformMath`, `SmartGuides`, `Viewport` and their test files. New geometry
(hit-testing, guide snapping, selection morphology) should be pure static
functions with their own tests, not methods on `CanvasController`.

Golden-image fixtures live in `DezzyTests/Fixtures/` (JSON + reference
PNGs); regenerate with `TEST_RUNNER_RECORD_FIXTURES=1`. Failures write
red-pixel diffs to `test-output/`.

`DebugSnapshot.swift` renders the whole window off-screen from launch
arguments, which covers most manual UI verification without needing a new
harness.

---

## What "done" looks like

1. `xcodebuild -project Dezzy.xcodeproj -scheme Dezzy test` passes,
   including the golden-image and performance tests (the §3 target is 8 layers
   at 6000×4000 within a 16.7 ms frame budget — don't regress the render path).
2. New pure geometry has its own unit tests, separate from the controller.
3. Every new menu command has a `validateUserInterfaceItem` case.
4. Every new document-mutating operation calls `commitPendingSessions()` first
   and produces exactly **one** history entry with a human-readable action name
   (check the Edit menu reads "Undo Paste", not "Undo").
5. Nothing mutates `Layer.source` in place or reuses a `sourceID` across
   different pixels.
6. Imported (non-paintable) layers still have byte-identical sources after the
   feature runs.
7. The feature has been exercised in a **Release** build — Debug performance is
   not representative.
8. A change to what scripts can do updates `ScriptAPIDeclaration` and, when
   it changes how a model should behave, passes the live evals
   (`TEST_RUNNER_DEZZY_EVAL=1 … -only-testing:DezzyTests/ChatEvalTests`).
