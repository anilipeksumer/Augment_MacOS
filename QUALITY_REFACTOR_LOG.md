# Quality Refactor Log

## 2026-06-26 - Phase 1 Started

- Scope: repo hygiene, test scaffold, shared defaults, AX safety, Finder bridge cleanup, and first-pass service extraction.
- Status: in progress.
- Verification: pending.
- Notes: keep user-facing behavior unchanged while reducing crash and maintenance risk.

## 2026-06-26 - Phase 1 Completed

- Status: completed.
- Changed files:
  - Added repo hygiene/docs: `.gitignore`, `README.md`, `QUALITY_REFACTOR_LOG.md`.
  - Added shared defaults source: `Augment/Shared/PreferenceDefaults.swift`.
  - Added safer AX coercion helpers: `Augment/Services/AXElementCoercion.swift`.
  - Added Finder bridge service extraction: `Augment/Services/FinderBridgeService.swift`.
  - Added MediaRemote adapter extraction: `Augment/Services/MediaRemoteProvider.swift`.
  - Added unit test target and tests under `AugmentTests`.
  - Updated `AppGroupConstants.swift`, `SharedPreferences.swift`, `WindowSnappingService.swift`, `WindowDiscoveryService.swift`, `MediaManager.swift`, `SettingsWindow.swift`, `AppDelegate.swift`, and `project.pbxproj`.
- Repo hygiene:
  - Removed generated `build/`, `.DS_Store`, and Xcode `xcuserdata` artifacts from the working tree.
  - Verification builds recreate `Augment/build`; it is ignored by `.gitignore`.
- Verification:
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme Augment -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO test` was blocked by the sandboxed environment: `com.apple.testmanagerd.control` lookup failed with sandbox restriction 159.
- Completed improvements:
  - Preference registration defaults now come from `PreferenceDefaults.registrationValues` for app, Finder extension, Quick Look extension, and shared preferences.
  - AX point, size, value, and element extraction now goes through guarded type checks in high-risk window discovery/snapping paths.
  - AX helper keeps the final CF bridge cast local and guarded by `CFGetTypeID`; Swift rejects optional downcasts for these CoreFoundation types.
  - Finder create/reveal queue handling moved out of `AppDelegate`; Darwin notification names now use bridge constants.
  - Finder reveal queue missing-directory failure now logs at low noise instead of silently returning.
  - Window snapping shortcut JSON parsing now has a pure static parser covered by tests.
  - MediaRemote private framework calls are isolated behind `MediaRemoteProvider`.
  - Media fetch/fingerprint work no longer does the full AppleScript/fallback scan on the main thread.
  - Initial unit coverage added for directory traversal budget, template collision naming, preference parity, shortcut fallback parsing, and AX wrong-type handling.
- Remaining risk / next phases:
  - Superseded by Phase 2: `DockPreviewCoordinator`, full MediaManager slicing, and Settings pane splitting were completed later in this log.
  - Manual smoke tests for Accessibility, Finder bridge, Dock preview, Quick Look folder preview, and Notch behavior still need to be run in an unsandboxed user session.

## 2026-06-26 - Phase 2 Started

- Scope: complete the previously deferred structural refactors: Dock preview coordination, full MediaManager slicing, Settings UI pane split, and final verification/log cleanup.
- Status: completed in the same work session.

## 2026-06-26 - Phase 2 Completed

- Status: completed.
- Changed files:
  - Added Dock behavior coordinator: `Augment/Services/DockPreviewCoordinator.swift`.
  - Added media service slices: `Augment/Services/MediaScriptRunner.swift`, `Augment/Services/ArtworkCache.swift`, `Augment/Services/AppleScriptMediaProvider.swift`, `Augment/Services/BrowserMediaProvider.swift`, and `Augment/Services/MediaCommandSender.swift`.
  - Added Settings pane files: `SettingsGeneralPane.swift`, `SettingsHoverPane.swift`, `SettingsWindowControlsPane.swift`, `SettingsDockClickPane.swift`, `SettingsDisplaysPane.swift`, `SettingsFinderPane.swift`, `SettingsWindowSnappingPane.swift`, `SettingsNotchPane.swift`, and `SettingsPermissionsPane.swift`.
  - Added Dock animation settings helper: `Augment/Services/DockEffectApplier.swift`.
  - Updated `AppDelegate.swift`, `MediaManager.swift`, `SettingsWindow.swift`, and `project.pbxproj`.
- Completed improvements:
  - `AppDelegate` is now focused on lifecycle wiring, menu actions, onboarding/permissions flow, and service startup/shutdown.
  - Dock click, hover preview, thumbnail actions, middle-click close, and lock-state filtering now live in `DockPreviewCoordinator`.
  - `MediaManager` keeps the public API (`shared`, `currentMedia`, `availableSources`, `activeSourceIndex`, `start/stop`, `sendCommand`) while delegating source detection, AppleScript/browser scraping, artwork caching, and command sending to dedicated services.
  - AppleScript and `/usr/bin/osascript` media work remains off the main actor through the provider/command abstractions.
  - Artwork state is centralized in `ArtworkCache` instead of scattered static variables.
  - `SettingsWindow.swift` is reduced to the controller, root shell, tab strip, and reusable row/container components; each settings area now has its own pane file.
  - Xcode user state artefacts generated during verification were removed again; ignore rules cover future regeneration.
- Verification:
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme Augment -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO test` was attempted and blocked by the sandboxed environment: `com.apple.testmanagerd.control` failed with sandbox restriction 159.
  - Brace balance check for all split `Settings*Pane.swift` files returned zero imbalance.
  - Artefact check after cleanup found no `.DS_Store`, `*.xcuserstate`, or `xcuserdata` paths under `Augment`.
- Size reduction checkpoints:
  - `AppDelegate.swift`: 271 lines.
  - `MediaManager.swift`: 330 lines.
  - `SettingsWindow.swift`: 393 lines.
- Remaining risk:
  - Full manual smoke testing still requires an unsandboxed macOS user session with Accessibility/Finder/Quick Look/Notch behavior available.
  - This refactor intentionally preserves private MediaRemote usage behind an adapter rather than removing it.

## 2026-06-26 - Phase 3 Started

- Scope: behavior and stability pass for reported OS blocking, media source control/play-pause state, Dock/Finder preview responsiveness, Finder queue reliability, and Quick Look cancellation.
- Status: completed in the same work session.

## 2026-06-26 - Phase 3 Completed

- Status: completed.
- Changed files:
  - `Augment/Services/MediaManager.swift`
  - `Augment/Services/MediaCommandSender.swift`
  - `Augment/Services/MediaScriptRunner.swift`
  - `Augment/Services/DockPreviewCoordinator.swift`
  - `Augment/Services/WindowDiscoveryService.swift`
  - `Augment/Services/FinderBridgeService.swift`
  - `Augment/Services/NotchService.swift`
  - `Augment/UI/MediaWidget.swift`
  - `Augment/UI/NotchContentView.swift`
  - `AugmentQL/FolderPreviewViewController.swift`
- Completed improvements:
  - Removed SwiftUI render-time disk logging from Notch/media views; this was a direct UI jank and filesystem churn risk.
  - Media fetches are now generation-guarded and single-flight, so stale asynchronous fetch results cannot overwrite newer media state.
  - User-selected media source is now pinned until that source disappears; automatic switching no longer steals control after the user chooses a source.
  - Media widget now exposes a source menu when multiple sources exist, not just previous/next arrows.
  - Play/pause/play/stop UI state updates optimistically immediately, then reconciles with real media state through delayed refreshes.
  - Spotify and Music play/pause commands now use explicit player-state AppleScript instead of relying on a generic `playpause` verb.
  - Media control and seek commands now run on a background queue, avoiding synchronous AppleScript blocking from button taps.
  - `/usr/bin/osascript` fallback has a timeout and terminates hung script processes instead of waiting indefinitely.
  - Dock preview thumbnail generation now runs on a serial background queue with generation checks; hover event handling no longer captures thumbnails synchronously.
  - Window thumbnail caches are lock-protected for the new background preview path.
  - Finder bridge queue processing now has a reentrancy guard, sorted/limited plist draining, and lower-noise logs for missing queue directories.
  - Quick Look folder previews now keep and cancel their build task when a new preview starts or the controller deinitializes.
- Verification:
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme Augment -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO test` was attempted and blocked by the sandboxed environment: `com.apple.testmanagerd.control` failed with sandbox restriction 159.
  - Xcode `xcuserdata` generated during verification was removed again.
- Manual smoke test focus:
  - Open Notch media with Spotify/Music/browser active, switch sources through the menu, and verify the selected source stays selected.
  - Press play/pause on a playing and paused source and verify the icon flips immediately and remains correct after refresh.
  - Hover Dock icons with many windows and verify UI remains responsive while thumbnails appear.
  - Hover Finder in Dock and verify desktop is not surfaced as a normal window.
  - Trigger Finder "New File with Augment" repeatedly and verify files are created once without duplicate queue handling.
  - Open Quick Look on a huge folder, dismiss quickly, and verify Finder/Quick Look remains responsive.
- Remaining risk:
  - Actual Accessibility, Finder Sync, and Quick Look behavior must still be smoke-tested in a normal unsandboxed user session.
  - Some AppleScript media integrations remain dependent on app-specific scripting support and macOS privacy prompts.

## 2026-06-26 - Phase 4 Started

- Scope: deeper stability pass after Phase 3, focused on remaining OS-freeze vectors and Finder bridge main-thread pressure.
- Status: completed in the same work session.

## 2026-06-26 - Phase 4 Completed

- Status: completed.
- Changed files:
  - `Augment/Services/MediaScriptRunner.swift`
  - `Augment/Services/FinderBridgeService.swift`
- Completed improvements:
  - Removed the timeout-free `NSAppleScript.executeAndReturnError` execution path from media scripting. Media scripts now use the `/usr/bin/osascript` runner with a 3 second timeout and process termination on hang.
  - Disabled Apple Music embedded-artwork extraction through raw AppleScript descriptors because that path required timeout-free `NSAppleScript`; artwork still falls back to MediaRemote data and store lookup.
  - Finder bridge queue draining now runs on a background `.utility` queue. File listing, plist decoding, template creation, retry/drop bookkeeping, and queue file deletion no longer run on the main actor.
  - Finder/UI side effects remain on the main actor: after background drain completes, the app reveals the last created file and requested reveal URLs through `NSWorkspace`.
- Verification:
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme Augment -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build` succeeded.
  - `xcodebuild -project Augment/Augment.xcodeproj -scheme AugmentTests -configuration Debug -derivedDataPath Augment/build CODE_SIGNING_ALLOWED=NO build-for-testing` succeeded.
  - Static scan found no live `NSAppleScript`, render-time disk debug logging, `.gemini/antigravity` scratch logging, `DispatchQueue.main.sync`, or semaphore usage in app/extension runtime code.
- Cleanup note:
  - Xcode regenerated `Augment/Augment.xcodeproj/project.xcworkspace/xcuserdata/.../UserInterfaceState.xcuserstate` during verification. Removal was attempted, but the escalated cleanup command was rejected by the execution environment usage limit, so this generated ignored artifact may still be present locally.
- Remaining risk:
  - Full confirmation of Dock hover, Finder Sync, Automation permission prompts, and Quick Look responsiveness still requires manual smoke testing in a normal unsandboxed macOS user session.

## 2026-06-26 - Phase 5 Started

- Scope: Implement 7 user requests covering UI updates, Finder integration, custom URL schemes, media player UX, and Quick Look extension bug fixes.
- Status: completed in the same work session.

## 2026-06-26 - Phase 5 Completed

- Status: completed.
- Changed files:
  - `Augment/Services/DockPreviewCoordinator.swift`
  - `Augment/UI/MediaWidget.swift`
  - `Augment/Services/MediaCommandSender.swift`
  - `AugmentQL/FolderPreviewViewController.swift`
  - `AugmentQL/DirectoryTreeFormatter.swift`
  - `Augment/UI/SettingsWindow.swift`
  - `Augment/UI/SettingsGeneralPane.swift`
  - `Augment/App/AppDelegate.swift`
  - `Augment/Services/FinderBridgeService.swift`
  - `Augment/Info.plist`
  - `Augment/Permissions/PermissionCoordinator.swift`
  - `Augment/UI/PermissionView.swift`
  - `Augment/UI/AboutWindow.swift`
- Completed improvements:
  - Fixed DockPreviewCoordinator to show an empty state when apps have no windows, but suppress it when apps are fully closed.
  - Removed up/down arrows in the Notch media selector and ensured play/pause media-key fallbacks route properly for unscriptable apps.
  - Fixed "Show in Finder" in Quick Look preview by utilizing `NSWorkspace` APIs instead of background helpers which sandbox prevents.
  - Implemented initial node collapse state in the DirectoryTreeFormatter for huge folder Quick Look performance and applied `content-visibility` CSS optimizations.
  - Redesigned `SettingsWindow` to use a left-hand navigation sidebar rather than a scrolling tab strip, which cleans up the crowded UI.
  - Cleaned up the `SettingsGeneralPane` UI to remove unnecessary drill-down navigation since the sidebar is now present.
  - Implemented reliable Apple Event (URL Scheme) routing `augment://` to deep link to the settings window and handled URL clicks natively in the QL extension's web view.
  - Bypassed recurring Accessibility prompt loops upon right-click file creations via the Finder sync extension.
  - Automatically drop into rename mode (simulating the return key) when creating a new file in Finder.
  - Developed a new premium `AboutWindow.swift` with SwiftUI, animations, floating particles, and gradient backgrounds.
  - Updated the `PermissionView` to properly layout its constraints, alongside a new `isPolling` flag indicating to the user when Augment is actively scanning for the newly-granted permission.
- Verification:
  - `xcodebuild -scheme Augment -workspace Augment.xcworkspace build` (No workspace found, used xcodeproj instead)
  - `xcodebuild -scheme Augment build` succeeded perfectly.
- Remaining risk:
  - User verification of visual elements. Some SwiftUI window placement behaviors might need adjustment across multiple displays.

## 2026-06-27 - Phase 6 Started

- Scope: Fix reported browser media state/control, About and Accessibility window lifecycle, Quick Look reveal, minimized-window hover, recurring Finder permission prompts, and live Notch settings preview.
- Status: completed in the same work session.

## 2026-06-27 - Phase 6 Completed

- Status: completed.
- Changed files:
  - `Augment.xcodeproj/project.pbxproj`
  - `Augment/App/AppDelegate.swift`
  - `Augment/Shared/AppGroupConstants.swift`
  - `Augment/Services/BrowserMediaProvider.swift`
  - `Augment/Services/MediaCommandSender.swift`
  - `Augment/Services/MediaManager.swift`
  - `Augment/Services/WindowDiscoveryService.swift`
  - `Augment/UI/AboutWindow.swift`
  - `Augment/UI/PermissionView.swift`
  - `Augment/UI/SettingsPermissionsPane.swift`
  - `Augment/UI/SettingsNotchPane.swift`
  - `AugmentFinder/FinderSync.swift`
  - `AugmentQL/FolderPreviewViewController.swift`
- Completed improvements:
  - Added the previously orphaned `AboutWindow.swift` to the Xcode target, routed the menu action to it, and added an explicit close button.
  - Accessibility state now refreshes when the app becomes active and when the Settings pane opens. The onboarding window has a working Close action and changes its primary action to Done after access is granted.
  - Browser media no longer displays the internal JavaScript permission error as artist text. Unknown browser playback state no longer overwrites optimistic play/pause UI state; MediaRemote remains authoritative when available.
  - System media-key event construction/posting is marshalled onto the main queue instead of invoking AppKit event APIs from a worker queue.
  - Minimized windows are supplemented from Accessibility using `AXWindowNumber`, so they can remain in Dock hover previews after disappearing from the on-screen CG window list.
  - Finder Sync no longer probes selected/targeted paths with `FileManager.fileExists` merely to resolve the destination. It derives the destination from Finder's menu context and delegates the write to the unsandboxed host queue.
  - Finder host cold-start uses the registered `augment://finder-bridge` URL instead of attempting to spawn `/usr/bin/open` from the sandboxed extension.
  - Quick Look reveal now enqueues a `FinderRevealBridge` request and wakes the host through `augment://finder-reveal`, with direct `NSWorkspace` reveal retained as an error fallback.
  - Notch Settings preview now observes the actual preference object and live-renders music controls, album/app indicators, calendar, shelf, battery, enabled state, and empty selection.
- Verification:
  - Main `Augment` build succeeded with both Finder Sync and Quick Look extensions.
  - `AugmentTests` `build-for-testing` succeeded.
  - Full `xcodebuild test` was attempted; execution was blocked by this environment's `com.apple.testmanagerd.control` sandbox restriction (error 159), not by a source/build failure.
  - Xcode project and all target plist files passed `plutil -lint`.
- Manual smoke test focus:
  - Play/pause a Chrome YouTube video with JavaScript-from-Apple-Events disabled and confirm clean metadata and stable icon state.
  - Open and close About from both the menu and titlebar; open Accessibility, close it, grant access, and confirm Done/dismissal behavior.
  - Reveal a nested folder from Quick Look while Augment is running and while it is quit.
  - Minimize all windows of an app, hover its Dock icon, then restore a minimized window from its preview.
  - Create several files from Finder context menus in Desktop/Documents and confirm no recurring Augment Accessibility or folder permission prompt.
  - Toggle each Notch widget option and confirm the Settings preview changes immediately.
- Remaining risk:
  - macOS TCC, Finder Sync, Quick Look, MediaRemote, and WindowServer behavior can only be fully confirmed in a normal signed user session; compile-time verification cannot simulate those system integrations.

## 2026-06-27 - Phase 7 Started

- Scope: Follow-up fixes for minimized Dock previews, native About/Permission windows, Chrome media artwork/state, configurable localized calendar and battery widgets, shelf drop feedback, idle resource use, and expanded New File templates.
- Status: completed in the same work session.

## 2026-06-27 - Phase 7 Completed

- Status: completed.
- Changed files:
  - `Augment/Shared/AppGroupConstants.swift`
  - `Augment/Shared/PreferenceDefaults.swift`
  - `Augment/Shared/SharedPreferences.swift`
  - `Augment/Services/WindowDiscoveryService.swift`
  - `Augment/Services/DockPreviewCoordinator.swift`
  - `Augment/Services/BrowserMediaProvider.swift`
  - `Augment/Services/AppleScriptMediaProvider.swift`
  - `Augment/Services/MediaManager.swift`
  - `Augment/Services/FinderBridgeService.swift`
  - `Augment/Services/NotchService.swift`
  - `Augment/UI/AboutWindow.swift`
  - `Augment/UI/OnboardingWindow.swift`
  - `Augment/UI/PermissionView.swift`
  - `Augment/UI/SettingsHoverPane.swift`
  - `Augment/UI/SettingsNotchPane.swift`
  - `Augment/UI/NotchContentView.swift`
  - `Augment/UI/MediaWidget.swift`
  - `AugmentFinder/FileTemplateFactory.swift`
  - `AugmentTests/FileTemplateFactoryTests.swift`
  - `AugmentTests/PreferenceDefaultsTests.swift`
- Completed improvements:
  - Minimized Dock windows are always requested by the coordinator. AX windows no longer disappear when an app omits `AXWindowNumber`: discovery falls back to a matching last-seen CG window and finally a deterministic synthetic ID.
  - Last-known window thumbnails and identities are retained in bounded caches across app-to-app hover, allowing minimized windows to reuse their most recent frame without unbounded memory growth.
  - About and Accessibility now use opaque, native titled/closable AppKit windows. Transparent full-size titlebars and continuous About animations were removed; titlebar Close, content Close, and Escape all close reliably.
  - About was redesigned as a restrained native product panel with app identity, version/build, core capability summary, author, and copyright.
  - Browser media with JavaScript-from-Apple-Events disabled starts with the correct playing state and preserves optimistic play/pause changes instead of resetting them on every poll.
  - Browser scripts now read the active tab URL without JavaScript permission. YouTube URLs produce asynchronously fetched, bounded-cache thumbnails from `i.ytimg.com`, which are applied to the matching Chrome/Safari source.
  - Added persistent `compact`/`badge`/`text` calendar styles and `gauge`/`symbol`/`percent` battery styles. Runtime date formatting explicitly uses `Locale.autoupdatingCurrent`; Settings controls and preview react live.
  - Shelf drop targeting now dims existing content, adds an accent dashed border, and animates a clear `Drop here to pin` target only while a file is actually being dragged.
  - Reduced idle work: media fallback polling 1.5s -> 3s at utility QoS, Finder queue safety polling 2s -> 15s, battery polling 10s -> 30s, media progress ticks 0.5s -> 1s and only update while expanded/playing.
  - Removed per-poll `NSImage.tiffRepresentation` conversion from media fingerprints and replaced it with object identity.
  - Expanded New File Coding templates with Java, Rust, Kotlin, C, C++, PHP, Ruby, and Dart; Data with XML and SQL; and added Project Files for Dockerfile, Makefile, `.env`, and `.gitignore`.
  - Collision-safe naming now supports extensionless and hidden files without trailing dots.
- Verification:
  - Main `Augment` build succeeded with Finder Sync and Quick Look extensions.
  - `AugmentTests` `build-for-testing` succeeded.
  - Direct `xcrun xctest Augment/build/Build/Products/Debug/AugmentTests.xctest` succeeded: 12 tests, 0 failures.
- Manual smoke test focus:
  - Minimize every window of Chrome/Finder/another app and confirm each Dock hover shows restorable rows instead of `No open windows`.
  - Open/close About and Accessibility repeatedly via titlebar, content button, and Escape.
  - Play and pause a YouTube tab with browser JavaScript automation disabled; verify pause while playing, play while paused, and thumbnail appearance after the asynchronous fetch.
  - Change macOS language/region and verify calendar labels update; switch all calendar/battery styles in Settings.
  - Drag a file over both empty and populated shelf states and verify the drop target appears only during drag.
  - Create the newly added coding, data, extensionless, and hidden project files from Finder.
- Remaining risk:
  - Some browsers can suppress active-tab URL AppleScript access via Automation/TCC policy; media controls still fall back to system media keys, but YouTube artwork then cannot be derived.
  - Thumbnail availability for a window minimized before Augment ever observed it depends on WindowServer capture policy; the row and restore action no longer depend on the thumbnail.

## 2026-06-27 - Phase 8 Started

- Scope: Diagnose and remove runtime console warnings reported after Phase 7, especially SwiftUI reentrant publishing and drag IPC reentrancy.
- Status: completed in the same work session.

## 2026-06-27 - Phase 8 Completed

- Status: completed.
- Changed files:
  - `Augment/Services/NotchService.swift`
  - `Augment/UI/NotchContentView.swift`
  - `Augment/UI/DockPreviewView.swift`
  - `Augment/UI/DockPreviewPanelController.swift`
- Diagnosis and improvements:
  - `Publishing changes from within view updates is not allowed` was app-originated. Preference publishers were synchronously assigning into the Notch observable model during Settings render/binding updates.
  - All Notch preference delivery now crosses an asynchronous main-queue scheduler boundary; notch hover expansion/collapse is also deferred out of SwiftUI's current view-update pass.
  - `DockPreviewViewModel` claimed to batch updates but combined one manual notification with multiple `@Published` notifications. Its render state is now plain storage with one explicit `ObservableObjectPublisher` event per snapshot/appearance transaction.
  - Snapshot removal now uses the same single-event model API instead of mutating observable storage directly.
  - Drop item loading is deferred until the AppKit drag IPC callback returns, removing the app-side trigger for `kDragIPCCompleted` reentrant drag messages.
  - `AFIsDeviceGreymatterEligible Missing entitlements...` is emitted by a macOS private eligibility lookup. Augment must not request Apple's private entitlement; the message is harmless framework noise.
  - `Unable to obtain a task name port right...` is emitted when WindowServer/Accessibility cannot inspect a protected process. The existing nil/failure path handles it without a crash; granting a private task-port entitlement is neither appropriate nor available.
- Verification:
  - Main `Augment` build succeeded with Finder Sync and Quick Look extensions and no new source/concurrency warnings.
  - `AugmentTests` `build-for-testing` succeeded.
  - Direct test execution succeeded: 12 tests, 0 failures.
- Manual smoke test focus:
  - Change every Notch and Dock preview setting while watching the Xcode console; no SwiftUI publishing warnings should repeat.
  - Enter/leave the notch repeatedly and drag files over and out of the shelf; no app-originated publishing or drag reentrancy flood should appear.
- Remaining note:
  - The two one-off macOS private-framework/protected-process diagnostic lines may still appear in Debug console and are not actionable application errors.

## 2026-06-27 - Phase 9 Started

- Scope: Dynamic Finder menu icon colors, a complete Augment macOS app icon, and Notch media command/progress freeze prevention.
- Status: completed in the same work session.

## 2026-06-27 - Phase 9 Completed

- Status: completed.
- Changed files:
  - `Augment/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
  - `Augment/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png`
  - `AugmentFinder/FinderSync.swift`
  - `Augment/Services/MediaCommandSender.swift`
  - `Augment/Services/MediaManager.swift`
  - `Augment/Services/NotchService.swift`
  - `Augment/UI/MediaWidget.swift`
- Completed improvements:
  - Finder menu SF Symbols now use a dynamic `NSColor.labelColor` palette instead of Finder Sync's unreliable black template-symbol rasterization. Icons follow light/dark appearance.
  - Generated and installed a complete Augment macOS app icon set at 16, 32, 64, 128, 256, 512, and 1024 pixel renditions. The build emits `AppIcon.icns` and declares both `CFBundleIconFile` and `CFBundleIconName`.
  - About continues to use `NSApp.applicationIconImage`, so it now renders the packaged icon instead of an empty placeholder.
  - Follow-up runtime fix: the app now explicitly loads `AppIcon.icns` from `Bundle.main`, assigns it to `NSApp.applicationIconImage`, and uses that same image in About and the menu bar. This bypasses the generic placeholder returned by Launch Services for accessory apps launched from Xcode.
  - Media commands now execute on one serial command queue; overlapping skip/seek/play requests cannot build a concurrent AppleScript/media-key backlog.
  - Notch media controls are briefly disabled while a command is in flight, preventing repeated clicks from racing the progress model.
  - Media fetches pause while commands are active. Fetches that began before a command are discarded if they contain stale track/progress data.
  - Command reconciliation refreshes are debounced to one immediate post-command fetch and one delayed verification fetch.
  - Progress hit testing is disabled during command settlement, resets on source changes, and advances by the actual one-second timer interval.
- Verification:
  - Main `Augment` build succeeded with Finder Sync and Quick Look extensions.
  - Built app contains `Contents/Resources/AppIcon.icns`; generated Info.plist references `AppIcon`.
  - Asset catalog JSON passed `jq` validation and all ten macOS icon slots have files.
  - `AugmentTests` `build-for-testing` succeeded; direct execution passed 12 tests with 0 failures.
- Manual smoke test focus:
  - Relaunch Finder/the newly built app, open the New File submenu in light and dark appearance, and verify icon contrast.
  - Open About and verify the new Augment icon.
  - Rapidly click previous/next and seek controls with Apple Music and Chrome sources; controls may dim briefly but the notch and progress bar must remain responsive.
