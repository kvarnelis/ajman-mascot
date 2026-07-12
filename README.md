# Ajman
Ajman is a native Swift/AppKit desktop mascot for macOS.
Stage 1 renders the existing 8×9 WebP spritesheet in a floating panel.
All nine animation states are available from the menu bar.
Requires macOS 14 or later and Swift 5.9 or later.
Build with `scripts/build-app.sh`.
The canonical app bundle is `build/Ajman.app`.
The root `Ajman.app` symlink points to that bundle.
Run by opening `Ajman.app` after building.
No network, Accessibility permission, or external dependencies are used.
