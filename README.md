<img width="760" height="554" alt="Brushy" src="https://github.com/user-attachments/assets/2c230453-36fc-49f9-b09b-9386050b0056" />

# Brushy

A small, native macOS image editor for the parts of Photoshop you actually use,
plus an AI sidebar that edits your document when you describe what you want.

- Layers, groups, blend modes, masks, clipping masks and layer styles
- Move, marquee, lasso, magic wand, crop, eyedropper, brush, eraser, gradient,
  text and shape tools
- Selections you can feather, modify and transform, plus Select Subject and Quick Mask
- Non-destructive transforms, guides and grid with snapping, and a history panel
- Opens and saves layered PSDs, layer styles included
- AI chat (⌘L): ask for an edit, generate an image, or select part of a photo
  and say "make this red". Needs a Gemini API key (Settings → AI).

macOS 14+, Apple Silicon.

## Install

Download the [latest release](https://github.com/nfarina/brushy/releases).
Brushy updates itself (Brushy → Check for Updates…).

## Build

Open `Brushy.xcodeproj` in Xcode and run, or build a signed Release copy into
`/Applications` (needs a Developer ID certificate):

```bash
./Scripts/local-install-app.sh
```

Use Release for real work: Debug builds paint about 10× slower.

Tests:

```bash
xcodebuild -project Brushy.xcodeproj -scheme Brushy test
```

## Releasing

```bash
./Scripts/publish-release.sh 0.2.0
```

This builds, signs, notarizes, creates the GitHub release, updates the Sparkle
appcast in `docs/`, and pushes. It prompts for release notes in `$EDITOR`, or
you can pass `--notes file.md`.

One-time setup:

- A Developer ID Application certificate in your keychain.
- A notarytool profile: `xcrun notarytool store-credentials brushy-notary`, or
  set `NOTARY_PROFILE=<name>` in `.env.release.local`.
- The Sparkle signing key in your keychain under `com.nfarina.Brushy`. Back it
  up: if it's lost, installed copies can't verify any future update.

## Credits

Brushy started as a fork of [Dezzy](https://github.com/mdhawley/Dezzy) by Matt
Hawley. MIT licensed; see `LICENSE.txt`.
