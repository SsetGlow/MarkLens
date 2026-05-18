# MarkLens

MarkLens is a native macOS Markdown editor focused on same-canvas writing: the center surface stays editable while Markdown receives live visual styling.

## Technology

- SwiftUI for the native macOS window, sidebar, toolbar, and app lifecycle.
- AppKit `NSTextView` / TextKit for the editor surface, chosen for startup speed, low memory use, undo support, and large-document text performance.
- Debounced file saves to reduce disk churn while typing.
- No Electron runtime, no local web server, and no browser page masquerading as an app.

## Build

```bash
./Scripts/build.sh
```

The app bundle is created at:

```text
.build/MarkLens.app
```

## Package

```bash
./Scripts/package_dmg.sh
```

The installer image is created at:

```text
dist/MarkLens-0.1.1-arm64.dmg
```

## Install Locally

```bash
cp -R .build/MarkLens.app /Applications/
open /Applications/MarkLens.app
```

## Homebrew Cask

After publishing the DMG as a GitHub release asset, the included cask can be used from a tap:

```bash
brew install --cask ./Casks/marklens.rb
```

The included cask tracks the release DMG URL and checksum.
