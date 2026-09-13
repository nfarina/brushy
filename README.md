# Brushy

A minimal native macOS image editor: layered, non-destructive, and deliberately
small. The success criterion is not feature count — it is that the handful of
operations it does have feel exactly the way your hands already expect, down to
the modifier keys.

Layers with blend modes, groups and clipping masks. Move, marquee, lasso, crop,
eyedropper, brush, eraser, gradient, text and shape tools. Selections that
feather, modify and transform, including Select Subject and Quick Mask. Non-destructive
transforms, layer effects, rulers/guides/grid with snapping, a history panel,
and PSD read/write. An AI chat sidebar (⌘L, or the button at the right of the
title bar) that edits the open documents from plain language by writing scripts
against a small JavaScript API — including an HTML Canvas 2D context over any
paint layer's pixels, so patterns, charts and custom artwork are one layer, not
a hundred. With a Gemini image model it can also generate a layer from a prompt,
and edit what you selected: select part of a photo, say "make this red", and the
model gets the area outlined in context and hands back a crop that lands as a new
layer masked to the selection. Tab hides every panel, Photoshop-style.

Deliberately out of scope for now: adjustment layers, filters, curves and levels,
healing and clone, and RAW.

macOS 14+, Apple Silicon. Swift + Core Image + an AppKit canvas + SwiftUI
chrome, no nibs. The one third-party dependency is
[Sparkle](https://sparkle-project.org), for updates.

Brushy began as a fork of [Dezzy](https://github.com/mdhawley/Dezzy) by Matt
Hawley.

## Download

[Latest release](https://github.com/nfarina/brushy/releases). It updates itself
through Sparkle (Brushy ▸ Check for Updates…).

## Build & run

Build Release for day-to-day use — Debug (`-Onone`) runs the brush engine's
CPU paths an order of magnitude slower. With a Developer ID certificate in your
keychain, this builds, signs the way releases are signed (so keychain "Always
Allow" survives rebuilds and updates), and swaps it into /Applications:

```bash
./Scripts/local-install-app.sh
```

Without one, build and copy it yourself:

```bash
xcodebuild -project Brushy.xcodeproj -scheme Brushy -configuration Release build
ditto "$(xcodebuild -project Brushy.xcodeproj -scheme Brushy -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/Brushy.app" ~/Applications/Brushy.app
open ~/Applications/Brushy.app
```

or open `Brushy.xcodeproj` in Xcode (16+) and run. `BRUSHY_DEMO=1` in
the environment (or launching with `--demo`) opens the hardcoded two-layer
demo composite instead of an empty document.

The AI sidebar needs a Gemini API key (Settings → AI, stored in the login
keychain; the `GEMINI_API_KEY` environment variable also works).

Headless UI checks (`DebugSnapshot`, all environment variables — an absolute
path in `argv` is taken by AppKit as a document to open and can wedge the app
in a modal error): `BRUSHY_SNAPSHOT=<png>` renders the window to disk and
exits, `BRUSHY_SNAPSHOT_STATE=<state>` puts the UI into one first
(`transform`, `crop`, `brush`, `guides`, `groups`, `effects`, `layerstyle`,
`settings`, `settingswindow`, `chat`, `panelshidden`, …), and `BRUSHY_OPEN=<file>` opens a
file through the app's real routing first — the way to see a `.psd` land as layers.
Sheets can't be captured (SwiftUI sheet content caches as bare control shapes, no
text), so dialog states embed the same view in the window instead.
`BRUSHY_SNAPSHOT_WINDOW=1` captures the window's theme frame — title bar and toolbar
included, Metal canvas blank — and `settingswindow` captures the real Settings window
the same way (`CGWindowListCreateImage` is no use: it returns white without Screen
Recording permission, even for the app's own windows). Snapshot runs disable keychain
prompts, because an ad-hoc-signed build gets one on its first key read after every
rebuild; signing the installed copy with an Apple Development identity makes "Always
Allow" stick.

## Tests

```bash
xcodebuild -project Brushy.xcodeproj -scheme Brushy test
```

Golden-image fixtures, P3 round-trip and linear-light checks, model
invariants, transform/smart-guide semantics, store/undo behaviour,
.brushy round-trip, display orientation, PSD read/write round trips
(including against a file ImageIO wrote, so the reader isn't only checked
against our own writer), an end-to-end place→edit→save→reopen→export pass,
and the performance target (8 layers @ 6000×4000; ~9.5 ms/frame on an M3
Ultra against the 16.7 ms budget).

Performance suites are order-fragile at full-suite scale — a full run
inflates frame times ~2×. Trust them only in isolation:

```bash
xcodebuild -project Brushy.xcodeproj -scheme Brushy test -only-testing:BrushyTests/PerformanceTests -only-testing:BrushyTests/GroupPerformanceTests -only-testing:BrushyTests/EffectsPerformanceTests
```

Live model evaluations (`ChatEvalTests`) send real requests to Gemini and
check the resulting documents — six plain-language tasks against the
configured chat model, a few cents per run. They skip unless asked for:

```bash
TEST_RUNNER_BRUSHY_EVAL=1 xcodebuild -project Brushy.xcodeproj -scheme Brushy test -only-testing:BrushyTests/ChatEvalTests
```

(`TEST_RUNNER_BRUSHY_EVAL_MODEL=gemini-3.5-flash-lite` tries another model;
the key comes from `GEMINI_API_KEY` or `~/.config/imagegen/secrets.env`.)

Golden fixtures live in `BrushyTests/Fixtures/` (JSON descriptions +
reference PNGs). Regenerate them with:

```bash
env TEST_RUNNER_RECORD_FIXTURES=1 xcodebuild -project Brushy.xcodeproj -scheme Brushy test -only-testing:BrushyTests/GoldenImageTests
```

Reference kinds (recorded in each fixture's JSON): `analytic` references come
from an independent CPU renderer in double precision (no Photoshop was
available, so absolute correctness is checked against closed-form math);
`recorded` references pin the Lanczos/rotation resampling paths as regression
baselines; `colorsync` references check colour conversion against ColorSync
independently of Core Image. Failures write red-pixel diffs to `test-output/`.

## Releasing

Releases are cut locally from the CLI:

```bash
./Scripts/publish-release.sh 0.2.0            # opens $EDITOR for release notes
./Scripts/publish-release.sh 0.2.0 --notes notes.md
```

That stamps `MARKETING_VERSION` and bumps `CURRENT_PROJECT_VERSION`, builds
Release, signs Brushy and Sparkle's nested helpers with Developer ID +
hardened runtime, notarizes and staples, creates the GitHub release with the
zip, signs a new `docs/appcast.xml` entry (EdDSA), then commits and pushes.
GitHub Pages serves the feed from `main:/docs` at
`https://nfarina.github.io/brushy/appcast.xml`, which `SUFeedURL` points at.

The steps run individually too: `local-release-build.sh <version>
[--skip-notarize]`, `generate-sparkle-appcast.sh <version> [--notes …]`.

One-time setup on a release machine:

- A "Developer ID Application" certificate in the login keychain (auto-detected;
  override with `APPLE_SIGNING_IDENTITY` / `APPLE_TEAM_ID`).
- A notarytool profile: `xcrun notarytool store-credentials brushy-notary`, or
  point `NOTARY_PROFILE` at an existing one in `.env.release.local` (gitignored).
- Sparkle's EdDSA private key in the login keychain under the account
  `com.nfarina.Brushy`. Its public half is `SUPublicEDKey` in `Config/Info.plist`.
  Losing the private key means shipped copies can never verify another update, so
  back it up: `build/sparkle-tools/<version>/extracted/bin/generate_keys --account
  com.nfarina.Brushy -x brushy-sparkle-key.txt`.

## Architecture notes

- `Brushy/Scripting` — the JavaScript API the AI (and, later, a CLI) drives.
  `ScriptSession` is a transactional copy of the open documents with a flat
  JSON-in/JSON-out op set over the pure `Document` ops; `ScriptPrelude` is
  the JavaScript object model (`brushy`, `doc`, `Layer`, `Group`) over one
  host call; `ScriptAPIDeclaration` is the `.d.ts` the model reads;
  `ScriptHost` runs a script in a fresh JavaScriptCore context with the
  execution-time watchdog (`JSContextGroupSetExecutionTimeLimit`, a private
  symbol — this app is not App Store bound); `ScriptRunner` snapshots, runs
  off-main, and commits one history entry per touched document, refusing to
  overwrite a document that changed underneath the script. Scripts see
  top-left, y-down coordinates and short ids (`doc1`, `l3fa9c1`);
  `ScriptGeometry` flips to canvas space. A script that throws applies
  nothing.
- `Brushy/AI` — the chat: `GeminiClient` (the Interactions REST API, stateless
  with streaming, thought signatures echoed verbatim), `ChatSession` (the
  tool loop: `execute`, `look`, `generate_image`), `ChatStore` (app-level
  chat list, JSON under Application Support), `ChatPrompt` (system prompt +
  the per-message [Context] block describing every open document, so most
  requests need no inspection round trip). The API key lives in the
  Keychain (`APIKeys`), never in `UserDefaults`.

- `Brushy/Model` — value-type `Document`/`Layer`/`Mask`. Sources are
  never mutated; crop shifts transforms only; masks are copy-on-write.
- `Brushy/Render` — the Core Image pipeline: linear Display P3
  working space, Lanczos beyond 50% downscale, `CIBlendWithMask` masking,
  graph rebuilt per frame. The view transform folds into each layer transform
  so display cost scales with viewport pixels, not canvas pixels.
- `Brushy/Store` — snapshot undo: an array of document+selection
  snapshots (100 deep by default and within a byte budget, both in Settings →
  Performance) bridged to `NSUndoManager` for menu names, projected read-only
  into the History panel.
- `Brushy/App/Defaults.swift` — the single `UserDefaults` path. Typed
  keys grouped into pane-sized domains, an injectable backing store so tests
  never touch the real domain, and a LIVE / SEED-ONLY tag on every key.
- `Brushy/UI/Canvas` — AppKit event handling; pure, unit-tested geometry
  (`TransformMath`, `SmartGuides`, `Viewport`) separated from the controller.
- `Brushy/Doc` — `NSDocument` + `.brushy` package: `document.json`,
  lossless `sources/*.png` (deduped across duplicated layers), `masks/*.png`.

Implementation choices worth knowing:

- Working-space conversion happens in float inside Core Image at render time
  (sources keep their original bytes, tagged with their profile; untagged
  imports are tagged sRGB). Equivalent to converting at import, without an
  8-bit quantisation step.
- The feather is an exact separable discrete Gaussian (sigma = feather/2,
  radius 3σ) via vImage — `CIGaussianBlur` is an approximation that deviates a
  few /255 from the golden references.
- EXIF orientation is baked in at import via an exact pixel permutation.
- Painting: brush (B) and eraser (E) with
  interpolated stamps (15% of diameter spacing), hardness falloff (Gaussian-ish
  at 0%, 1px antialiased edge at 100%), a per-stroke opacity ceiling, X/D
  colour keys, [ ] size and ⇧[ ⇧] hardness keys, and a live size-ring cursor.
  Strokes preview through a Core Image overlay and bake once on mouse-up — one
  undo step per stroke. The brush paints masks (black hides / white reveals)
  and paint layers (Layer → New Paint Layer, ⇧⌘N); imported sources are never
  painted — the eraser on a photo auto-creates a hide-mask instead, keeping
  even erasing non-destructive. An active selection is a stencil: paint lands
  inside it and nowhere else, at its strength where it is soft.
- Text edits in place on the canvas: T-click seeds a
  fully-selected "Lorem Ipsum" placeholder so typing replaces it (committing
  it untouched leaves no layer — a deliberate deviation from convention), and a
  floating task bar under the box carries font/size/colour plus
  cancel/commit, tracking the box through zoom, pan, rotation, and growth.
  Clicking existing text edits it at the click point. Return adds a line,
  Enter/⌘Return/click-away commits, Esc cancels.
  The editor is an NSTextView on the shared TextKit 1 stack, bounds-scaled so
  editing layout is bitmap-identical to the committed raster (tested); the
  document is never mutated mid-session (the renderer just excludes the layer),
  typing gets its own undo, and each session commits as one snapshot.
- Text (T) and shape (U) layers are supported: live-editable specs
  (string/font/size/colour; rectangle/ellipse/line with fill, stroke,
  solid/dashed/dotted styles and per-end arrowheads) that re-rasterize into
  the layer source on edit, anchored so text grows downward and shapes stay
  centred. Text-tool clicks on existing text edit it; shape styles are
  editable from the options bar after creation.
- Layer → Flip Horizontal/Vertical and Rotate 90° Left/Right compose into the
  layer transform (non-destructive). Edit → Fill Selection fills with the
  foreground/background colour (⌥⌫/⌘⌫ on the canvas) — on masks with its
  luminance, on paint layers as pixels; imported photos stay untouched.
- Export… includes **PSD (layered)**: write-only PSD v1 (RGB 8-bit, raw
  channels) with layer rasters (transforms baked), names (Pascal + Unicode),
  visibility, opacity, layer masks and the export ICC profile, plus a
  flattened composite for viewers. Validated by an independent test-side PSD
  parser and an ImageIO decode check.
- Image → Image Size… (⌥⌘I) and Canvas Size… (⌥⌘C) are supported
. Image Size scales layer *transforms* — no pixels
  are resampled, so repeated resizes are lossless; Canvas Size is anchored
  (9-way) and, like crop, never clips layer content.
- The Gradient tool (G) is supported — the headline use is a black→
  white linear ramp on a mask, the standard two-photo blend. Drag defines the
  vector (⇧ constrains to 45°); the options bar has linear/radial shapes, a
  foreground→transparent mode (on masks the transparent end leaves the mask
  untouched) and Reverse. Routing mirrors Edit → Fill: masks take the
  colours' luminance ramp, paint layers take pixels (fresh source), imported
  photos stay untouched; an active selection clips the bake, and beyond the
  dragged span the ramp clamps to its end colours across the whole target.
  Bakes once on mouse-up as one "Gradient" undo step — the drag shows the
  vector line only, not a live full-gradient preview.
- Quick Mask (Q, or the toggle under the colour chips): the selection becomes
  an 8-bit channel shown as Photoshop's 50% red rubylith, painted with the
  brush, filled and gradient-faded like any mask, and undone stroke by stroke.
  Leaving traces it back at 50% — and keeps the channel as the selection's
  coverage, so a gradient-faded selection stays faded through Fill, Delete,
  Copy and Add Layer Mask. Selecting still works with the mask up — a marquee
  made inside Quick Mask limits where painting it lands — and ⌫ fills the
  channel with the background colour. ⌘-clicking a layer's thumbnail loads its
  alpha the same way. Path-only selections (everything else) behave as before;
  reshaping one that has coverage — a boolean, Select ▸ Modify, a scaled
  Transform Selection — drops the channel and says so in a toast.
- Dragging inside a selection with the marquee or lasso moves the outline,
  not the pixels (⇧ constrains it, and ⇧/⌥ at mouse-down still mean
  add/subtract) — one "Move Selection Outline" undo step.
- Select → Select Subject: Vision's foreground-instance mask (macOS 14's
  `VNGenerateForegroundInstanceMaskRequest`) runs on the selected layer's own
  source off the main thread, and the mask is vectorized (subpixel marching
  squares in `SubjectMask`) into an ordinary selection path — one undo step
  that feathers, masks, cuts, and modifies like any selection.
- Layer blend modes: the 16 standard modes with exact Core Image equivalents, grouped by
  family in a popup beside the panel's opacity slider.
  These modes are conventionally defined over gamma-encoded document-space
  values, so non-normal modes run through a linear→encoded→linear tone-curve
  sandwich (verified analytically against the closed-form math); Normal keeps
  the untouched linear-light fast path, and PSD export writes Adobe's
  4CC blend keys.
- Clipping masks are supported (⌥⌘G, ⌥-click a layer thumbnail, or
  the context menu): a run of consecutive clipped layers confines to the
  alpha of the nearest unclipped layer below, blends against that base's
  content, and lands on the composite as one group — base opacity and blend
  mode apply once — the standard "blend clipped layers as group". Membership
  is positional (reorders re-resolve it; the bottom layer is never clipped)
  and clipped rows indent with a ↳ badge.
- New documents start with a transparent "Layer 1", so a
  fresh canvas is immediately brushable. While that blank is pristine — no
  edits in either undo direction — and the canvas wasn't explicitly sized,
  content arrivals (place, paste, drop, cross-document transfer) replace it
  and adopt their frame, preserving the open-into-a-fresh-window semantics;
  ⌘N-sized documents keep their Layer 1 and place content above it.
- Layer groups are supported (⌘G Group Layer / ⇧⌘G Ungroup, folder
  rows with disclosure + rename + eye + drag-reorder in the panel).
  `Document.layers` stays flat in render order; membership is
  `Layer.groupID` plus a parallel `groups` table (nesting via `parentID`)
  under one invariant — a group's subtree occupies a contiguous run, runs
  nest — enforced by `normalizingGroups()`. Groups default to
  PASS THROUGH: organizational only, zero render-graph cost, bit-identical
  to ungrouped (test-pinned). Opacity < 100% or an explicit mode (Normal
  included — distinct from Pass Through) isolates: members flatten over
  transparency, then composite once through the same linear-light opacity
  and gamma-sandwich blend paths as layers. Group visibility cascades over
  render, hit-testing, Copy Merged, export and tool enablement; clip runs
  scope to the group (boundaries break them, first-of-scope clips release
  like bottom-of-stack); Merge Down refuses to cross a boundary; arrivals
  (paste, transfer, new layers) adopt the selected layer's group, while
  membership itself never travels off-document. Folder disclosure persists
  in the file but stays out of undo (patched through history snapshots).
  PSD export writes Adobe `lsct` section dividers (open/closed folder +
  `pass` blend key) so Photoshop opens real folders. Deferred: group masks,
  transfer/copy of whole groups (member layers transfer fine), empty
  groups (deleting a group's last member dissolves the group), and
  clipping a layer TO a group as its base.
- Layer effects (layer styles) are supported ('s
  layer-style exclusion lifted by the owner, with `.psd` reading below).
  Seven effects: Drop Shadow, Inner Shadow, Outer Glow, Inner Glow, Stroke,
  Colour Overlay and Gradient Overlay, each a non-destructive Core Image
  pass built from the layer's own coverage (`LayerEffectRenderer`).
  The conventional split is preserved: Drop Shadow and Outer Glow land outside the
  layer and blend onto the BACKDROP with their own modes, while the other
  five fold into the layer's fill and blend with the layer's mode; layer
  opacity scales the finished style, effects included. Sizes and distances
  are canvas points, so an effect is independent of the layer's own scale
  (the PSD model has no layer transforms). Gradient Overlay interpolates on
  gamma-encoded values, as such ramps are conventionally defined, and decodes
  back to linear.
  A layer with no style renders through the pre-effects graph unchanged
  (test-pinned, byte-identical), so the frame budget is untouched;
  switched-off effects cost nothing. UI: Layer → Layer Style (and the
  panel's "Blending Options…"), a single effects dialog that previews live
  and lands ONE undo step, plus an `fx` badge on styled rows. Merge Down
  bakes the style and grows to fit it. Deferred: Bevel & Emboss, Satin and
  Pattern Overlay (a lighting model and a pattern library, respectively);
  contours, noise and multi-stop gradient ramps.
- Reading `.psd` is supported.
  `PSDReader` opens a `.psd` file as real layers: pixels, position,
  Unicode names, opacity, visibility, blend modes, clipping, user masks,
  nested folders (`lsct` dividers), the embedded ICC profile, and layer
  styles (`lfx2` — see below). 8- and 16-bit RGB and grayscale documents;
  RAW, RLE and ZIP channel data. Layers arrive straight-alpha, keeping the
  file's own bytes. Anything unreadable as
  layers — CMYK/Lab/indexed/32-bit, `.psb`, or a file with no layer section
  — falls back to the flattened composite as one layer rather than refusing
  to open. `.psd` opens into an untitled document (no `fileURL`), so ⌘S
  can't overwrite it through the `.brushy` serializer.
- Layer styles cross the PSD boundary in both directions: `PSDDescriptor`
  implements Adobe's descriptor format and `PSDEffects` maps it to
  `LayerEffects`, so a styled layer exported from Brushy opens in
  Photoshop as live, editable effects — and a styled Photoshop layer comes
  back the same way. Written channel data deliberately excludes the style
  (Photoshop applies `lfx2` itself; baking it would double it). Note the two
  distinct blend-mode encodings in one file: 4CC keys in the layer record
  (`mul `), descriptor enum keys in the style (`Mltp`). Photoshop's "Scale
  Effects" is folded into the numbers on read. Effects Photoshop has and
  this app doesn't (Bevel, Satin, Pattern) are dropped on read; the rest of
  the style survives.
- Multi-layer selection plus Align & Distribute. The store keeps a
  `selectedLayerIDs` set as the source of truth and `selectedLayerID` as the
  ANCHOR — single-layer commands (mask, Free Transform, Layer Style, Edit
  Text, brush targeting) still act on the anchor alone and never fan out. The
  panel's `List(selection:)` takes the set, so ⇧-range and ⌘-toggle come from
  AppKit; on canvas ⇧ keeps BOTH its meanings by deferring the decision to
  mouse-up — a press that never travels 3 screen px was a ⇧-click (toggle
  membership), anything further is a ⇧-drag (constrain to 45°). Selection
  rides the undo history with the same liveness filtering the anchor gets.
  `Model/AlignOps.swift` holds the pure geometry: six aligns and two
  distribute modes (equal GAPS — the default — vs equal centres) against the
  canvas or the selection's bounds, translation only so nothing resamples,
  working from each object's AABB (which is also what a rotated layer aligns
  by). A selected group is ONE object — one delta for the whole folder —
  hidden layers are skipped, clipped layers move with their base instead of
  aligning alone, degenerate bounds drop out, and each command is exactly one
  undo step. Surfaced on the Move tool's options bar (with an "Align
  To" picker, forced to Canvas below two objects) and in Layer ▸ Align /
  Distribute.

- A standard Settings window (⌘,) was added, and with it one persistence path
  instead of two: the view-furniture `ViewDefaults` enum inside `DocumentStore`
  and the New Document dialog's ad-hoc `UserDefaults` keys both moved into
  `App/Defaults.swift`. Raw key names are unchanged, so upgrading loses no
  settings. Six panes — General, Guides & Grid, Tools, Performance, Color, AI —
  each with a Reset scoped to its own domain. The window is an AppKit
  `NSTabViewController` in toolbar style (the tabs are the window's toolbar,
  `.preference` style, titled after the pane), which is what a native Settings
  window is; a SwiftUI `TabView` in a plain `NSWindow` only imitates it and
  collapsed every tab into an overflow menu at six. App-scoped (one shared
  `NSWindowController`, not parented to a document), so ⌘, works with no
  document open and survives every document closing.
  The split that matters: **seed-only** settings are read once when a
  `DocumentStore` / `BrushyDocument` / Export sheet is created and affect
  only the *next* one; **live** settings — grid spacing and subdivisions,
  guide and grid colours, snapping, undo depth — hang off an `AppSettings`
  singleton that open documents mirror, so they apply immediately to already
  open windows. Lowering the undo depth trims open histories from the front
  right away rather than at the next commit. No setting, either kind, ever
  enters the undo history.

- A History panel shares the right column with
  the Layers panel behind a Layers/History segmented control. Every snapshot
  carries the command name `commit` already hands `NSUndoManager`, so rows
  read "Brush Stroke", "Free Transform", … above an opening "New"/"Open"
  row; clicking a row jumps there by replaying `undoStep`/`redoStep` inside
  one undo group, so ⌘Z afterwards is a single "Undo State Change" and
  the undo stack never desynchronises from the array. Rows past the current
  position are the redo tail and render dimmed. The action name is
  deliberately OUTSIDE `Snapshot`'s equality, so a differently-named no-op
  still dissolves against the history top instead of adding a row.
  History also has a **byte budget** beside the 100-step count cap. Most
  operations snapshot for free (shared `CGImage` sources, copy-on-write
  masks), but every brush stroke bakes a new full-size bitmap: measured,
  100 strokes on a 6000×4000 layer retained 9.6 GB. Snapshot cost is the
  ref-counted union of distinct `sourceID` bitmaps and `storageIdentity`
  mask buffers across the whole history — so 50 states sharing one source
  cost one image, not 50 — and the oldest states are evicted until both caps
  hold, with the panel footer saying so. Deferred: per-state thumbnails
  (100 composites for little payoff), history brush, and snapshots.
