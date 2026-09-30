# Building Augment

## Requirements

- Xcode 26 or later
- macOS 13 or later to run; the volume mixer needs macOS 14.2

## Build

```bash
git clone https://github.com/anilipeksumer/Augment_MacOS.git
cd Augment_MacOS
open Augment.xcodeproj
```

Build and run the **Augment** scheme. To use the Finder extension, run the app from `/Applications` and switch the extension on in System Settings › General › Login Items & Extensions.

## Project layout

| Target | What it is |
| --- | --- |
| `Augment` | The menu bar app. Not sandboxed — it needs Accessibility, event taps and Core Audio process taps. |
| `AugmentFinder` | Finder Sync extension: right-click menu and the cut badge. |
| `AugmentQL` | Quick Look extension that previews folders as a tree. |

The app and its sandboxed extensions share settings through a plist in `~/Library/Application Support/Augment/Shared/` (the extensions have a matching temporary-exception entitlement). Finder requests that need an unsandboxed process — creating files, opening Terminal — are queued there and picked up by the app via a Darwin notification.

## Tests

Augment has a built-in functional test runner. It drives features the way a user would and writes results to `~/Library/Application Support/Augment/functest.log`.

```bash
# Everything (moves the mouse and uses the keyboard for a couple of minutes)
open -n /Applications/Augment.app --args --functest

# Checks that don't touch the mouse or keyboard
open -g -n /Applications/Augment.app --args --functest --extras

# Renders the notch, panels and settings pages to ~/Library/Application Support/Augment/shots
open -g -n /Applications/Augment.app --args --functest --notch-render
open -g -n /Applications/Augment.app --args --functest --settings-shots
```

Launch the app with `open` rather than running the binary from Terminal: macOS attributes permissions to the process that launches it.

## Release

```bash
xcodebuild -project Augment.xcodeproj -scheme Augment -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Augment.xcarchive archive
xcodebuild -exportArchive -archivePath build/Augment.xcarchive -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist   # method: developer-id
```

Then put the app in a DMG, sign the DMG with the Developer ID certificate, notarize it with `xcrun notarytool submit … --wait` and staple the ticket with `xcrun stapler staple`.

### Show Desktop

`ShowDesktopService` registers a Carbon global hotkey and sets each application's
window `AXMinimized` attribute through Accessibility. Cross-process calls run on
a serial background queue with a per-call timeout; calls targeting Augment itself
return to the main thread because they invoke AppKit directly. `DesktopWindowSession` tracks
only successful minimizations, preserving windows that were already minimized.
Full-screen windows and windows that reject minimization are left unchanged.
The quick panel exposes a compact desktop/restore icon beside Settings.

Run `open -n /Applications/Augment.app --args --functest --desktop` to verify
real minimization/restoration using only temporary windows in the test process.

For manual regression testing, enable Show Desktop in Settings → Windows and
check the shortcut, Option-click on the menu bar icon, and quick panel button.
Repeat each action to restore windows. Include already minimized windows,
multiple displays and Spaces. Holding the shortcut must only trigger once on
release. Disabling the feature must release the hotkey; a conflicting app must
produce a warning in Settings without disabling mouse access.
