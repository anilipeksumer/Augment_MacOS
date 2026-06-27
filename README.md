# Augment

Augment is a macOS utility that adds Dock hover previews, Windows-style Dock click behavior, Finder file templates, Quick Look folder previews, window snapping, and an optional interactive notch overlay.

## Targets

- `Augment`: menu bar host app.
- `AugmentFinder`: Finder Sync extension for the New File menu.
- `AugmentQL`: Quick Look extension for folder previews.
- `AugmentTests`: unit tests for pure logic and safety helpers.

## Build And Test

```sh
xcodebuild -project Augment.xcodeproj -scheme Augment -configuration Debug build
xcodebuild -project Augment.xcodeproj -scheme AugmentTests test
```

## Runtime Permissions

Dock interaction, window controls, and window snapping require Accessibility permission. Window thumbnails may require Screen Recording permission depending on macOS privacy settings. Finder and Quick Look extensions use the shared App Group `group.com.anilipeksumer.augment`.
