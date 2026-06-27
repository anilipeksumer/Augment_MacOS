# Augment macOS Feature Rollout

This document tracks the implementation status of the 15-item user request
that drove the Apr 2026 stabilization-and-features push. It is the
durable cross-chat companion to the plan stored in
`.cursor/plans/macos_dock_ux_revamp_plan_facc223d.plan.md`.

Update the **Status** column whenever you finish a task; follow up notes
go beneath each phase under "Notes / decisions".

Legend: `done` `in-progress` `todo` `n/a`

---

## Phase 1 – Stabilization & persistence

| #   | Item                                                                                                  | Status | Where                                                                                                                                                                              | Notes                                                                                                                                          |
| --- | ----------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Dock icon click does not close the open app, app keeps coming back                                    | done   | `Augment/App/AppDelegate.swift` (`toggleMinimizeRestore`, `handleClick`, new `handleMiddleClick`)                                                                                  | Click still toggles minimize per macOS expectations; middle-click on a Dock icon now closes all windows for the app (gated by Settings).       |
| 2   | Permission keeps re-prompting on every relaunch                                                       | done   | `Augment/Permissions/PermissionCoordinator.swift`, `Augment/App/AppDelegate.swift`, `Augment/Shared/SharedPreferences.swift` (`hasRequestedAccessibilityPrompt`)                  | Prompt fires once per install; quietly polls afterwards. Settings → Permissions has a “Re-prompt” button for explicit retries.                 |
| 4   | Settings revert when re-opened after a change                                                         | done   | `Augment/Shared/SharedPreferences.swift` (`write` funnel + `synchronize`)                                                                                                          | Every write goes through a single funnel that immediately calls `defaults.synchronize()` on the App Group container.                            |
| 6   | Hover on closed app still shows a panel                                                               | done   | `Augment/App/AppDelegate.swift` (`canShowPreview`), `Augment/Services/WindowDiscoveryService.swift` (`hasVisibleStandardWindows`)                                                  | Suppressed by default (toggleable in Settings → Hover → "Suppress empty previews").                                                            |
| 14  | Folder Quick Look hierarchy is broken                                                                 | done   | `AugmentQL/PreviewProvider.swift`, `AugmentQL/DirectoryTreeBuilder.swift`, `AugmentQL/DirectoryTreeFormatter.swift`                                                                | Higher budgets, hidden files at root level, two open levels by default, empty-folder placeholder, master Settings toggle.                       |

### Notes / decisions
- Permission prompt is surfaced via the new `hasRequestedAccessibilityPrompt`
  preference so it survives reinstalls only by design (user can wipe the
  App Group container to reset).
- `defaults.synchronize()` is technically deprecated for app-suite cases,
  but it is the most reliable workaround for cross-extension consistency
  and Apple still ships the API; we accept the warning for now.

---

## Phase 2 – Finder menu & feature flags

| #   | Item                                                                          | Status | Where                                                                                                                                                                       | Notes                                                                                                                          |
| --- | ----------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| 3   | Right-click "New File" errors + categorize menu                                | done   | `AugmentFinder/FinderSync.swift`, `AugmentFinder/FileTemplateFactory.swift`                                                                                                | Submenu now groups templates into Coding, Microsoft Office, Data, Text. Pre-validates target dir, surfaces errors clearly.     |
| 15  | Toggle for every major feature                                                | done   | `Augment/UI/SettingsWindow.swift`, `Augment/Shared/SharedPreferences.swift`                                                                                                  | Master toggles for hover, dock click, folder QL, Finder menu, dock lock, traffic lights, kill button, middle-click, drag-out. |

### Notes / decisions
- `FileTemplateWriter.create` now pre-checks `isWritableFile(atPath:)` and
  returns a localized error so writing into `/Applications` etc. doesn't
  silently fail.
- Categories are intentionally implemented via per-category submenus so
  Finder doesn't render disabled section headers (which look like bugs in
  contextual menus).

---

## Phase 3 – Hover UX upgrades

| #   | Item                                                            | Status | Where                                                                                                                                                                       | Notes                                                                                                              |
| --- | --------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| 9   | Middle-click on hover thumbnail closes the window               | done   | `Augment/UI/MouseEventCatcher.swift`, `Augment/UI/WindowThumbnailCell.swift`, `Augment/Services/DockInteractionService.swift`, Settings toggle                              | Wheel-click thumbnails or Dock icons. Strong scroll-down also closes.                                              |
| 10  | Drag-out from hover opens the window normally                   | done   | `Augment/UI/WindowThumbnailCell.swift` (`conditionalDrag`), `Augment/App/AppDelegate.swift` (`handleDragOut`)                                                              | Drag triggers AX raise + activation; the window stays where it was, mimicking "pulled out of the panel".          |
| 11  | Hover header shows logo + name + Close All / Minimize All       | done   | `Augment/UI/DockPreviewView.swift` (header + actions), `Augment/UI/DockPreviewPanelController.swift` (callbacks)                                                            | Action chips fade in when the user hovers the header. Toggleable.                                                  |
| 13  | Pressing Space over hover panel enlarges the preview            | done   | `Augment/UI/DockPreviewPanelController.swift` (`installKeyMonitorIfNeeded`, `toggleMagnification`), `Augment/Shared/SharedPreferences.swift` (`spaceMagnifyEnabled`)         | Space toggles a Finder-style magnified preview; magnification suppresses auto-hide so the user can read.           |

### Notes / decisions
- `MouseEventCatcher` only intercepts events it cares about
  (`otherMouseDown`, `scrollWheel`); normal taps/drags continue to land in
  the SwiftUI gesture system.
- Drag-out is implemented as a focus side-effect; the actual `NSItemProvider`
  payload is symbolic ("augment.window") so future drop-target integrations
  can ride on top.

---

## Phase 4 – Traffic-light controls

| #   | Item                                                                                                                              | Status | Where                                                                                                                                                                | Notes                                                                                  |
| --- | --------------------------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| 5   | macOS-style traffic-light controls + side selection + force-kill button on opposite side, with toggle to show/hide the kill button | done   | `Augment/UI/WindowThumbnailCell.swift`, `Augment/UI/SettingsWindow.swift` (`WindowControlsSettingsPane` + `TrafficLightPreview`)                                     | Settings → Window Controls hosts the toggle, side picker, kill button toggle, preview. |
| 7   | Tie minimize effect to macOS preference (or remove if not feasible)                                                               | done   | `Augment/Shared/SharedPreferences.swift` (`DockMinimizeEffect.system`), `Augment/UI/SettingsWindow.swift` (`DockEffectApplier.apply`)                                | Default is now `system`, which leaves macOS in charge. Other choices remain optional.  |
| 8   | Make Settings more illustrative                                                                                                   | done   | `Augment/UI/SettingsWindow.swift` (`PaneHeader`, `ToggleRow`, `TrafficLightPreview`, `ScreenLayoutPreview`)                                                            | Each pane now has hero header (gradient + bouncing icon), iconified toggle rows, live previews. |

### Notes / decisions
- AX has no public "force quit window" affordance, so the kill button uses
  `NSRunningApplication.forceTerminate()` against the window's owner PID,
  which is the same channel the user would hit via `kill(1)`.

---

## Phase 5 – Multi-display dock lock

| #   | Item                                                                       | Status | Where                                                                                                                                                                                                                                                                                       | Notes                                                                                                                                                            |
| --- | -------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 12  | Dock locking with selectable screens + visual layout preview                | done   | `Augment/Services/ScreenGeometry.swift`, `Augment/Services/DockInteractionService.swift` (`allowEventAtPoint`), `Augment/UI/DockPreviewPanelController.swift` (`preferredScreenProvider`, side-aware `computeFrame`), `Augment/UI/SettingsWindow.swift` (`DisplaySettingsPane`)             | Settings → Displays renders a clickable layout preview, persisting selected displays via `lockedScreenIdentifiers`.                                              |

### Notes / decisions
- Identities are stored as `localizedName#displayID` so reconfiguring
  monitors (different display ID, same name) still resolves.
- The panel-side detection in `computeFrame` keeps the panel anchored
  correctly when the Dock is on the left or right.

---

## Cross-cutting improvements

- **Master feature flags** are surfaced in `SharedPreferences` and
  `AppGroupConstants` so all extensions (`Augment`, `AugmentFinder`,
  `AugmentQL`) read from the same source of truth.
- **Settings revamp** introduces a `PaneHeader` / `ToggleRow` / preview
  vocabulary that other settings panes can reuse going forward.

## Smoke test checklist (manual)

1. Hover an icon for an app that is not running → no panel appears.
2. Hover an icon for an app that is running → panel shows after the dwell.
3. Hover header → Close All / Minimize All chips appear.
4. Middle-click a hover thumbnail → that window closes; remaining windows
   re-render in place.
5. Middle-click a Dock icon → all the app's windows close.
6. Drag a thumbnail away from the panel → that window receives focus.
7. Press Space while hovering → panel grows to magnified size; press again
   → returns.
8. Right-click in Finder → New File submenu shows categorized entries.
   Pick one → file appears and is selected in Finder.
9. Press Space on a folder → tree preview shows two levels open with
   sizes and item counts.
10. Settings → toggle every flag, close, re-open → flags persist.
11. Settings → Window Controls → switch side → traffic-light preview
    flips. Toggle Kill button → opposite-side dot appears in preview.
12. Settings → Displays → enable Dock Lock + select one display → hovering
    Dock from a non-locked screen shows nothing.
13. Settings → Permissions → "Re-prompt" → macOS prompt appears (only
    works when state is denied).
14. Quit and relaunch Augment → no permission prompt.
15. Settings → Dock Click → choose "System" minimize effect → Augment
    leaves the macOS-wide setting alone (Dock does not relaunch).

---

## Phase 6 – Follow-up bug fixes (Apr 30 batch)

| #   | Item                                                                                                  | Status | Where                                                                                                                                                          | Notes                                                                                                                                          |
| --- | ----------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 16  | Dock icon click: window minimizes then immediately pops back                                          | done   | `Augment/Services/DockInteractionService.swift` (default tap + `shouldHandleLeftClick`), `Augment/App/AppDelegate.swift` (`toggleMinimizeRestore`)                | The CGEventTap is now a default tap; clicks over Dock icons are swallowed when the feature is on, so the system Dock cannot race our minimize. AppDelegate now handles inactive-app activation itself. |
| 17  | Settings: drill-down from the General features list into per-feature detail (with back button)       | done   | `Augment/UI/SettingsWindow.swift` (`GeneralSettingsPane` wraps `NavigationStack`, new `FeatureNavRow`)                                                            | Each row in the General pane's Features section is now a navigation link with an inline switch. Existing tabs continue to render the same panes for users who prefer top-level navigation. |
| 18  | Finder: rename root entry to "New File with Augment"; fix "permission" error when creating files     | done   | `AugmentFinder/FinderSync.swift` (menu rename + scoped access), `AugmentFinder/FileTemplateFactory.swift` (drop misleading preflight), `Augment/UI/SettingsWindow.swift` | Menu now reads "New File with Augment". The handler wraps writes in `startAccessingSecurityScopedResource()` and the writer no longer pre-fails on `isWritableFile`, which was returning false for many sandbox-reachable folders. |
| 19  | "Dock lock" should pin the **macOS Dock itself** to the chosen display                                | done   | `Augment/Services/DockInteractionService.swift` (`confineCursorAwayFromDockZoneIfNeeded`), `Augment/UI/SettingsWindow.swift` (Displays pane copy)                | macOS exposes no API to bind the Dock to a display, so Augment now lifts the cursor out of the bottom-edge Dock-summon zone of non-locked screens. The Settings pane states the limitation plainly. |
| 20  | Middle-click closes the window but the thumbnail lingers in the hover panel                          | done   | `Augment/UI/DockPreviewPanelController.swift` (`removeSnapshotOptimistically`), `Augment/App/AppDelegate.swift` (`closeWindow`, `minimizeWindow`)                | The panel now drops the closed/minimized thumbnail immediately; the follow-up AX re-render still runs ~120ms later to reconcile any drift.    |
| 21  | Toggling a feature off then back on does not re-enable it                                              | done   | `Augment/Shared/SharedPreferences.swift` (`currentBool(forKey:)`), `AugmentFinder/FinderSync.swift`, `AugmentQL/PreviewProvider.swift`                            | Extensions live in their own processes and only see the value `@Published` had at load. They now re-read the latest value from the App Group on every menu/preview request. |
| 22  | Settings revert on relaunch                                                                            | done   | `Augment/Shared/SharedPreferences.swift` (`write` funnel), `Augment/Shared/AppGroupConstants.swift` (cached suite), `Augment/App/AppDelegate.swift` (`applicationWillTerminate`), extensions                                                                  | `AppGroup.defaults` is now a cached singleton, every write also calls `CFPreferencesAppSynchronize` against the suite, terminate flushes once more, and both extensions share `SharedPreferences.shared`. |
| 23  | Folder Space-preview hierarchical tree is broken; keep counts / size / modified date                  | done   | `AugmentQL/DirectoryTreeBuilder.swift` (`modifiedAt`), `AugmentQL/DirectoryTreeFormatter.swift` (header + per-row meta + CSS)                                     | Each row now renders item count (for directories), modified date, and size; the header also prints the folder's own modification date.       |

### Notes / decisions
- Item 19 requires honesty: macOS does not publish a way to bind the
  Dock to a specific screen. The implementation will reframe the toggle
  as "Lock Augment to one display" and document the platform limit in the
  Displays pane plus this doc, rather than ship a hack that breaks across
  OS updates.
- Item 17 keeps the existing tabs functional: drill-down is a parallel
  affordance from the General pane, not a replacement.

---

## Phase 7 – Regression sweep & UX polish (Apr 30 evening batch)

| #   | Item                                                                                                  | Status | Where                                                                                                                                                          | Notes                                                                                                                                          |
| --- | ----------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 24  | Dock lock filter does not actually keep events off the unlocked screens                               | done   | `Augment/Services/DockInteractionService.swift`, `Augment/Services/ScreenGeometry.swift` (new `isCGPoint`, `convertFromCG`, `convertToCG`)                       | `CGEvent.location` is now converted to AppKit coords through a single shared helper before the screen-membership check, so multi-display setups no longer silently fall through to the wrong screen. The cursor warp uses the inverse helper. |
| 25  | Folder Quick Look only shows the system preview, not the Augment tree                                 | done   | `AugmentQL/PreviewProvider.swift`, `AugmentQL/DirectoryTreeFormatter.swift`                                                                                    | Once the App Group preference flush (item 29) is in place the extension can read `folderQuickLookEnabled` reliably. The tree header now shows an "Augment Folder Preview" brand chip so the user can confirm the extension fired vs. the system fallback at a glance. |
| 26  | "New File with Augment" Finder menu icons do not honor the system theme                               | done   | `AugmentFinder/FinderSync.swift` (`templateSymbol`)                                                                                                             | Every SF Symbol on the menu is now `isTemplate = true`, so Finder tints the parent, category headers, and template rows with the system menu color (light, dark, and accent variants). |
| 27  | Settings drill-down shows ugly `>>` chevrons; needs a modern back button                              | done   | `Augment/UI/SettingsWindow.swift` (`FeatureNavRow`, `DetailContainer`, `GeneralSettingsPane`)                                                                   | Rows are now plain `Button`s that push a `FeatureDestination` onto a `NavigationPath`, so the disclosure indicator never renders. Each detail pane wraps in `DetailContainer` with a single `chevron.backward` "General" toolbar button (also bound to ⌘[). |
| 28  | Console: "Publishing changes from within view updates is not allowed"                                 | done   | `Augment/App/AppDelegate.swift` (`observePreferenceChanges`, `observePermissionState`), `Augment/UI/DockPreviewView.swift` (`update`, `updateAppearance`)        | Combine subscribers now `.receive(on: DispatchQueue.main)` so they always defer to the next runloop tick instead of dropping into an in-flight render. The view-model batches its multi-property writes behind a single `objectWillChange.send()`. |
| 29  | cfprefsd warning + clicking a Dock icon for a not-running app does nothing                            | done   | `Augment/Shared/SharedPreferences.swift` (`synchronizeAppGroup`), `Augment/Services/DockInteractionService.swift`, `Augment/App/AppDelegate.swift`               | App Group flushes now use `CFPreferencesSynchronize(suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)`, which is the call cfprefsd actually permits for App Group containers. The Dock click filter takes the bundle ID and refuses to swallow events for apps that are not running yet, so macOS can launch them normally. |
| 30  | Close All keeps the hover panel visible after every window is gone                                    | done   | `Augment/App/AppDelegate.swift` (`closeAllForBundle`, `minimizeAllForBundle`)                                                                                  | Both handlers now `hideImmediately()` and cancel the pending hover-open up front; the existing `rerenderPanelAfterMutation` still runs to reconcile any AX races. |
| 31  | Permission and settings prompts re-fire on every relaunch                                             | done   | resolved transitively via item 29                                                                                                                               | The prompt persistence flag rides on the same App Group write path; once `synchronizeAppGroup` stopped detaching from cfprefsd, `hasRequestedAccessibilityPrompt` survives relaunch and the dialog is suppressed unless the user explicitly hits "Re-prompt". |
| 32  | Settings re-opens onto the last drilled-in pane instead of the home view                              | done   | `Augment/UI/SettingsWindow.swift` (`SettingsWindowController.show`, `SettingsRootView`, `GeneralSettingsPane`)                                                  | `show()` posts an `augment.settings.shouldReset` notification; the root view resets the selected tab back to General and the General pane resets its `NavigationPath`, so every Settings open lands on the home view. |
| 33  | Force-quit pane crashes with `No symbol named 'circle.grid.3x1.fill' found in system symbol set`      | done   | `Augment/UI/SettingsWindow.swift` (`WindowControlsSettingsPane`)                                                                                                | The traffic-light toggle now uses `macwindow`, which ships in every macOS that meets the deployment target. |

### Notes / decisions
- Item 24 isolates the coordinate fix from the dock-lock UX; once the
  geometry is consistent, the panel anchoring (Phase 5) and event filter
  share a single source of truth.
- Item 25 acknowledges that Quick Look does not give an extension two
  panels. The plan is to make the Augment HTML the *one* preview surface
  the user gets, with a "system-style" summary header sitting above the
  tree.
- Item 29 is the highest-impact regression: the same root cause (broken
  App Group preference flush) shows up as the cfprefsd warning, the
  permission prompt re-firing (item 31), and indirectly the Dock-click
  swallowing because feature toggles are evaluated against stale
  preferences.

---

## Open follow-ups

- macOS does not expose a clean way to scope the *minimize* animation per
  app. Item 7 is satisfied by reverting to the system preference; if a
  per-app override becomes feasible (e.g. via a private Dock plist key),
  we can revisit.
- The drag-out gesture (item 10) currently focuses the window in place.
  A fully-featured "tear out" that lets the user drop the window onto a
  Space/screen will require coordinated AX move calls against
  `kAXPositionAttribute`; tracked here as a future enhancement.
