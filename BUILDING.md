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

Package with the original installer layout (background, arrow, icon positions and Finder window):

```bash
scripts/package-dmg.sh build/export/Augment.app build/Augment-1.0.8.dmg
codesign --sign "Developer ID Application: ANIL IPEKSUEMER (LUPJND3R24)" --timestamp build/Augment-1.0.8.dmg
xcrun notarytool submit build/Augment-1.0.8.dmg --keychain-profile Augment-release --wait
# Continue only after the result is Accepted.
xcrun stapler staple build/Augment-1.0.8.dmg
xcrun stapler validate build/Augment-1.0.8.dmg
```

The packaging script clones the checksum-pinned 1.0.6 installer and replaces only
Augment.app. It downloads that template from the 1.0.6 release if absent locally.
Do not replace this with a plain `hdiutil create -srcfolder`: that loses the
installer layout. Open the resulting DMG in Finder and visually verify the layout
before publishing. Calculate the release checksum after stapling.

To refresh the README Settings image, launch the installed release app with
`--functest --readme-settings`. It captures the actual English window in dark
appearance, writes `~/Library/Application Support/Augment/shots/readme-settings.png`,
and restores the user's language preference afterward.

### Show Desktop

`ShowDesktopService` registers a Carbon global hotkey and sets each application's
window `AXMinimized` attribute through Accessibility. Cross-process calls run on
a serial background queue with a per-call timeout; calls targeting Augment itself
return to the main thread because they invoke AppKit directly. `DesktopWindowSession` tracks
only successful minimizations, preserving windows that were already minimized.
Every invocation first checks Window Server visibility on the current desktop.
Visible application windows take priority over saved history; newly minimized
windows are added to the existing group. Only a clear desktop allows restoration.
Full-screen windows and windows that reject minimization are left unchanged.
The quick panel exposes a compact desktop/restore icon beside Settings.

Run `open -n /Applications/Augment.app --args --functest --desktop` to verify
real minimization/restoration using only temporary windows in the test process.
Use `--functest --hotkey-routing` to verify that Command-D and Command-Shift-V
remain isolated when both Carbon hotkey handlers are installed.

For manual regression testing, enable Show Desktop in Settings → Windows and
check the shortcut, Option-click on the menu bar icon, and quick panel button.
After minimizing, open a new window and invoke again: it must minimize without
restoring the previous group. Invoke once more on the clear desktop to restore
the combined group. Also manually restore one window and repeat. Include already minimized windows,
multiple displays and Spaces. Holding the shortcut must only trigger once on
release. Disabling the feature must release the hotkey; a conflicting app must
produce a warning in Settings without disabling mouse access.

### Finder Enter modes

Settings → Finder offers native macOS behavior (default), Shift-Enter to open,
and Enter to open with Shift-Enter to rename. The two custom modes require
Accessibility only. Events are remapped to Finder's native Command-O or Return;
[Apple documents Command-O as Open](https://support.apple.com/en-us/102650).
Focused text controls and dialogs are excluded, and paired key-up events keep
the action chosen on key-down. Other modifiers and applications pass through.

Quit the normal Augment instance, then run
`open -n /Applications/Augment.app --args --functest --finder-open` for the
Finder integration checks. They create and clean up a temporary test folder and
Finder window. They also open a temporary text file in its default application
and close its document window via Accessibility. Test setup uses Finder Automation permission; the feature itself
does not need Automation. Do not type or switch apps during this keyboard test.


### Finder extras and image clipboard

Quit the normal app before running
`open -n /Applications/Augment.app --args --functest --finder-extras`.
This exercises Backspace, F2, image paste with duplicate names, middle-click
new tabs, empty-space double-click, image history persistence and a real
screenshot imported from a temporary folder. It preserves the general
pasteboard and uses a separate history store for image tests.

Finder image paste and new-tab navigation use Finder Automation outside the
event tap. The other shortcuts use Accessibility. Synthesized Finder events
are tagged to bypass Augment's own Enter modes and window snapping.

Image bytes are normalized to PNG and stored by content hash under
`Shared/ClipboardImages`. History metadata stays in the existing plist.
Images over 32 MiB or 64 megapixels are skipped. The image store is capped at
200 MiB by removing the oldest unpinned image entries; the existing 40-entry
limit for unpinned history also applies. Deleting or clearing an entry removes
its stored image, while pinned entries survive clearing. Screenshot import
watches macOS's configured screenshot folder and does not scan older captures
or require Spotlight indexing. Clipboard screenshots (Control-Shift-Command-3/4)
are captured through the ordinary image pasteboard path.

Use `--functest --screenshot-feedback` to verify the collapsed arrival animation,
its timeout and repeated captures, preservation of an open notch tab, and image
clipboard persistence. It does not type into Finder or other applications.
