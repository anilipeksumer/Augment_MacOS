import CoreFoundation
import Foundation

/// Command-line arguments parsed only by the Augment **host app** (menu-bar target).
/// Finder Sync and other helpers pass these via `NSWorkspace` / `open(1)` when
/// launching the host for a lightweight task (e.g. draining the Finder create queue).
public enum AugmentHostLaunchArgument {
    /// Skip onboarding + Accessibility **prompt** flow; only refresh trust state and drain queues.
    /// Used when the host was started solely to satisfy a Finder “New File” bridge request.
    public static let finderBridge = "--finder-bridge"
}

/// Shared identifiers and keys used across the main app and bundled extensions.
///
/// All three targets (`Augment`, `AugmentFinder`, `AugmentQL`) share this module
/// so keys and App Group file paths stay aligned.
///
/// **Storage backend: a plist file in a plain shared folder, not the App
/// Group container and not `CFPreferences`.** This app pairs a sandboxed
/// FinderSync/QuickLook extension with an *unsandboxed* host. Two things
/// that look like they should work here do not, on current macOS:
///
/// 1. `cfprefsd` rejects every write an unsandboxed process makes into a
///    `CFPDContainerSource` for an App Group domain — logged as "rejecting
///    write of key(s) <private> … because setting these preferences requires
///    user-preference-write or file-write-data sandbox access".
/// 2. The App Group **container directory itself** (`~/Library/Group
///    Containers/group.…`) refuses the unsandboxed host both read and write
///    access outright ("You don't have permission…") — only a sandboxed
///    process holding the matching container's sandbox extension can touch
///    it, and declaring the entitlement without *being* sandboxed doesn't
///    grant that.
///
/// Both failed silently: Settings toggles looked like they worked (the
/// in-memory `@Published` value did change) but nothing ever reached disk or
/// the extensions, and `FinderCreateBridge`/`FinderRevealBridge` (§ below)
/// could never actually be read by the host. The fix is a directory the
/// *host* can reach with zero entitlements (any path under its own
/// `~/Library/Application Support`) and the *extensions* reach via an
/// explicit `temporary-exception.files.home-relative-path.read-write`
/// entitlement naming this exact path (declared in
/// `AugmentFinder.entitlements` / `AugmentQL.entitlements`).
public enum AppGroup {
    /// The App Group identifier shared by every Augment target. Still used
    /// for the app-group entitlement itself (required to *exist* even though
    /// its container can't be used for host/extension IPC) — not for any
    /// path lookups any more.
    public static let identifier: String = "group.com.anilipeksumer.augment"

    /// Plain shared folder both the unsandboxed host and the sandboxed
    /// extensions (via a temporary-exception entitlement) can read and write.
    public static var sharedDirectory: URL {
        realHomeDirectory
            .appendingPathComponent("Library/Application Support/Augment/Shared", isDirectory: true)
    }

    /// The user's real home folder. Inside a sandboxed extension
    /// `homeDirectoryForCurrentUser` is the extension's container instead,
    /// which would split host and extensions into two different stores.
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Posted (distributed) whenever the Finder cut set changes.
    public static let fileCutChangedNotification = Notification.Name("com.anilipeksumer.augment.fileCutChanged")

    private static let storeFileName = "AugmentSharedPreferences.plist"
    private static let lock = NSLock()
    private static var cache: [String: Any] = loadFromDisk()

    private static var storeURL: URL? {
        sharedDirectory.appendingPathComponent(storeFileName)
    }

    private static func loadFromDisk() -> [String: Any] {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any]
        else { return [:] }
        return dict
    }

    /// Writes a property-list value into the shared store and flushes to
    /// disk immediately for cross-process visibility. Pass `nil` to remove
    /// the key.
    public static func setSuiteValue(_ value: CFPropertyList?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
        persistLocked()
    }

    /// Reads a value from the in-memory cache — call `synchronizeSuitePreferences`
    /// first to pick up another process's writes (e.g. `SharedPreferences.init`).
    public static func copySuiteValue(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    /// Re-reads the shared plist from disk so another process's writes
    /// become visible before a batch of reads.
    @discardableResult
    public static func synchronizeSuitePreferences() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        cache = loadFromDisk()
        return true
    }

    /// Must be called with `lock` held.
    private static func persistLocked() {
        guard let url = storeURL else {
            NSLog("Augment: AppGroup persistLocked – containerURL is nil")
            return
        }
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: cache, format: .binary, options: 0
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Augment: AppGroup persistLocked – write FAILED at %@: %@", url.path, error.localizedDescription)
        }
    }

    /// Default values for each key in the App Group suite.
    public static let suiteRegistrationDefaults = PreferenceDefaults.registrationValues

    /// Reads a boolean for extensions / lightweight call sites.
    public static func preferencesBool(forKey key: String) -> Bool {
        synchronizeSuitePreferences()
        return boolFromCopiedPlist(copySuiteValue(forKey: key))
            ?? (suiteRegistrationDefaults[key] as? Bool)
            ?? false
    }

    public static func preferencesDouble(forKey key: String) -> Double {
        synchronizeSuitePreferences()
        if let pref = copySuiteValue(forKey: key) as? Double { return pref }
        if let num = copySuiteValue(forKey: key) as? NSNumber { return num.doubleValue }
        return (suiteRegistrationDefaults[key] as? Double) ?? 0.0
    }

    private static func boolFromCopiedPlist(_ pref: Any?) -> Bool? {
        guard let pref else { return nil }
        if let b = pref as? Bool { return b }
        if let num = pref as? NSNumber { return num.boolValue }
        return nil
    }
}

/// Strongly-typed keys for values shared across the App Group container.
///
/// Centralizing the key names here avoids typo bugs across the targets and
/// gives Xcode autocomplete coverage when reading or writing preferences.
public enum AppGroupKey {
    // MARK: - Onboarding & permissions
    public static let didCompleteOnboarding = "augment.didCompleteOnboarding"
    /// Whether the user has been shown the Accessibility prompt at least
    /// once. Prevents the prompt from re-firing on every relaunch.
    public static let hasRequestedAccessibilityPrompt = "augment.hasRequestedAccessibilityPrompt"
    /// Finder Sync sets this right before cold-launching the host so it can skip permission UX
    /// even when Launch Services drops CLI args / environment (common for GUI apps).
    public static let pendingFinderBridgeHostLaunch = "augment.pendingFinderBridgeHostLaunch"

    // MARK: - Language
    public static let appLanguage = "augment.appLanguage"

    // MARK: - Master feature toggles
    public static let dockClickBehaviorEnabled = "augment.dockClickBehaviorEnabled"
    public static let windowPreviewsEnabled = "augment.windowPreviewsEnabled"
    public static let folderQuickLookEnabled = "augment.folderQuickLookEnabled"
    public static let folderQuickLookShowWarning = "augment.folderQuickLookShowWarning"
    public static let finderNewFileMenuEnabled = "augment.finderNewFileMenuEnabled"
    public static let dockLockEnabled = "augment.dockLockEnabled"

    // MARK: - Hover preview
    public static let hoverOpenDelay = "augment.hoverOpenDelay"
    public static let previewSize = "augment.previewSize"
    public static let previewCloseButtonVisible = "augment.previewCloseButtonVisible"
    /// Adds Close All / Minimize All affordances next to the preview header.
    public static let headerActionsEnabled = "augment.headerActionsEnabled"
    /// Whether hovering on previews supports middle-click to close windows.
    public static let middleClickCloseEnabled = "augment.middleClickCloseEnabled"
    /// Whether previews support dragging a window out of the panel.
    public static let dragOutEnabled = "augment.dragOutEnabled"
    /// Whether Space toggles a magnified Finder-like quick preview.
    public static let spaceMagnifyEnabled = "augment.spaceMagnifyEnabled"
    /// Whether the panel should suppress when the app under the cursor isn't
    /// running (or has no candidate windows). Default: true.
    public static let suppressEmptyPreviews = "augment.suppressEmptyPreviews"
    /// When true, Dock hover previews may appear even if every window is minimized.
    public static let showHoverWhenMinimized = "augment.showHoverWhenMinimized"

    // MARK: - Window controls (traffic-light style)
    /// Side on which the macOS-style traffic-light controls render.
    public static let trafficLightSide = "augment.trafficLightSide"
    /// Master toggle for the traffic-light controls themselves.
    public static let trafficLightEnabled = "augment.trafficLightEnabled"
    /// Whether the opposite side hosts a destructive "kill app" button.
    public static let killButtonVisible = "augment.killButtonVisible"

    // MARK: - Dock minimize effect (legacy, kept for migration)

    // MARK: - Multi-display dock lock
    /// Comma-separated list of preferred screen IDs the dock interaction
    /// stays bound to when `dockLockEnabled` is on. Empty means primary.
    public static let lockedScreenIDs = "augment.lockedScreenIDs"

    // MARK: - Window snapping
    /// Master toggle for Cmd+Arrow window snapping.
    public static let windowSnappingEnabled = "augment.windowSnappingEnabled"
    /// JSON-encoded dictionary mapping snap directions to custom shortcut
    /// configurations. Each entry contains modifier flags and a key code.
    public static let windowSnappingShortcuts = "augment.windowSnappingShortcuts"

    // MARK: - Window cut & paste (⌃⌘X / ⌃⌘V)
    /// Master toggle for cutting a window and re-placing it elsewhere,
    /// modeled on the Windows 11 "cut & paste to move windows" feature.

    // MARK: - File cut & paste (⌘X / ⌘V in Finder)
    /// Master toggle for a real Finder "Cut" (Finder natively only has
    /// Copy + ⌥⌘V paste-as-move).
    public static let finderEnterBehavior = "augment.finderEnterBehavior"
    public static let fileCutPasteEnabled = "augment.fileCutPasteEnabled"

    // MARK: - Snap Layouts (⌃⌥Space)
    /// Master toggle for the Windows 11-style snap-zone picker flyout.
    public static let showDesktopEnabled = "augment.showDesktopEnabled"
    public static let snapLayoutsEnabled = "augment.snapLayoutsEnabled"

    // MARK: - Window switcher (⌥Tab)
    /// Master toggle for the thumbnail-based ⌥Tab window switcher.
    public static let windowSwitcherEnabled = "augment.windowSwitcherEnabled"

    // MARK: - Menu bar organizer
    /// Master toggle for the menu-bar icon hide/reveal spacer.

    // MARK: - Volume mixer (per-app volume, macOS 14.2+ process taps)
    /// Master toggle for the per-app volume mixer.
    public static let volumeMixerEnabled = "augment.volumeMixerEnabled"

    // MARK: - External display control (experimental DDC/CI)
    /// Master toggle for external-display brightness/volume sliders in the notch.

    // MARK: - Notch (BoringNotch)
    /// Master toggle for the interactive notch overlay.
    public static let notchEnabled = "augment.notchEnabled"
    /// Individual widget toggles.
    public static let notchMusicWidget = "augment.notchMusicWidget"
    public static let notchBatteryWidget = "augment.notchBatteryWidget"
    public static let notchShelfWidget = "augment.notchShelfWidget"
    public static let notchMediaControlsEnabled = "augment.notchMediaControlsEnabled"
    public static let notchShowAppIcon = "augment.notchShowAppIcon"
    public static let notchShowAlbumArt = "augment.notchShowAlbumArt"
    public static let notchCalendarEnabled = "augment.notchCalendarEnabled"
    public static let notchCalendarStyle = "augment.notchCalendarStyle"
    public static let notchBatteryStyle = "augment.notchBatteryStyle"
    public static let notchHoverDelay = "augment.notchHoverDelay"
    /// Master toggle for the clipboard history feature, surfaced as a tab
    /// inside the notch's file-shelf widget.
    public static let clipboardHistoryEnabled = "augment.clipboardHistoryEnabled"

    /// Whether the keep-awake toggle button is shown in the notch top bar.
    public static let notchCaffeinateWidget = "augment.notchCaffeinateWidget"

    /// Whether the quick note + Pomodoro timer widget is shown.
    public static let notchProductivityWidget = "augment.notchProductivityWidget"
    public static let notchPomodoroMinutes = "augment.notchPomodoroMinutes"
    public static let notchMirrorEnabled = "augment.notchMirrorEnabled"
    public static let pauseOnHeadphonesRemoved = "augment.pauseOnHeadphonesRemoved"
    public static let quickPanelDisplays = "augment.quickPanelDisplays"
    public static let quickPanelStats = "augment.quickPanelStats"
    public static let quickPanelSound = "augment.quickPanelSound"
    public static let quickPanelMic = "augment.quickPanelMic"
    public static let quickPanelMeetings = "augment.quickPanelMeetings"
    public static let quickPanelAwake = "augment.quickPanelAwake"
    public static let displayKeysEnabled = "augment.displayKeysEnabled"
    public static let brightnessScheduleEnabled = "augment.brightnessScheduleEnabled"
    public static let brightnessDayStart = "augment.brightnessDayStart"
    public static let brightnessNightStart = "augment.brightnessNightStart"
    public static let brightnessDayLevel = "augment.brightnessDayLevel"
    public static let brightnessNightLevel = "augment.brightnessNightLevel"
    public static let awakeDisplayMaySleep = "augment.awakeDisplayMaySleep"
    public static let awakeWhileApps = "augment.awakeWhileApps"
    public static let awakeOnPower = "augment.awakeOnPower"
    public static let awakeWhileDownloading = "augment.awakeWhileDownloading"
    public static let awakeLidClosed = "augment.awakeLidClosed"
    public static let clipboardPanelEnabled = "augment.clipboardPanelEnabled"
    public static let meetingsEnabled = "augment.meetingsEnabled"
    public static let screenshotShelfEnabled = "augment.screenshotShelfEnabled"
    public static let finderExtraMenuEnabled = "augment.finderExtraMenuEnabled"
    /// Persisted text of the notch quick-note scratchpad.
    public static let notchQuickNoteText = "augment.notchQuickNoteText"
    /// POSIX paths currently marked with Finder ⌘X; the Finder extension badges them.
    public static let fileCutPaths = "augment.fileCutPaths"

    /// Persisted pinned URLs for the file shelf
    public static let notchShelfURLs = "augment.notchShelfURLs"
}

// MARK: - Finder “New File” bridge (extension → host app)

/// The Finder Sync extension is sandboxed and sometimes cannot obtain a
/// security-scoped URL that covers the user’s Desktop / Documents even
/// after `startAccessingSecurityScopedResource` (for example when the
/// contextual menu was opened on a selected file and we derive the parent
/// folder path by string manipulation). The main Augment app is **not**
/// sandboxed, so it can create the file and read template binaries from
/// the embedded `AugmentFinder.appex` bundle.
public enum FinderCreateBridge {
    /// `templateTag` value meaning "a new folder" rather than a file template.
    public static let newFolderTag = -1

    /// Darwin notify name – must stay in sync with the observer in
    /// `AppDelegate`.
    public static let darwinNotificationName = CFNotificationName(
        "com.anilipeksumer.augment.finderCreate" as CFString
    )

    public struct Request: Codable {
        public let templateTag: Int
        public let directoryPath: String
        /// Incremented when the host fails to create so we can retry without losing the request.
        public var attempt: Int

        enum CodingKeys: String, CodingKey {
            case templateTag
            case directoryPath
            case attempt
        }

        public init(templateTag: Int, directoryPath: String, attempt: Int = 0) {
            self.templateTag = templateTag
            self.directoryPath = directoryPath
            self.attempt = attempt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            templateTag = try c.decode(Int.self, forKey: .templateTag)
            directoryPath = try c.decode(String.self, forKey: .directoryPath)
            attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        }
    }

    public static var queueDirectory: URL? {
        AppGroup.sharedDirectory.appendingPathComponent("FinderCreateQueue", isDirectory: true)
    }

    /// Writes one plist into the shared App Group and pings the host app.
    public static func enqueue(_ request: Request) throws {
        guard let dir = queueDirectory else {
            throw NSError(
                domain: "FinderCreateBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing App Group container."]
            )
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).plist")
        let data = try PropertyListEncoder().encode(request)
        try data.write(to: file, options: [.atomic])
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            darwinNotificationName,
            nil,
            nil,
            true
        )
    }
}

// MARK: - Finder "Reveal" bridge (Quick Look extension → host app)

public enum FinderRevealBridge {
    public static let darwinNotificationName = CFNotificationName(
        "com.anilipeksumer.augment.finderReveal" as CFString
    )

    public struct Request: Codable {
        public let filePath: String
        /// nil = reveal in Finder; "terminal" = open a Terminal window there.
        public var action: String?
        public init(filePath: String, action: String? = nil) {
            self.filePath = filePath
            self.action = action
        }
    }

    public static var queueDirectory: URL? {
        AppGroup.sharedDirectory.appendingPathComponent("FinderRevealQueue", isDirectory: true)
    }

    public static func enqueue(_ request: Request) throws {
        guard let dir = queueDirectory else {
            throw NSError(
                domain: "FinderRevealBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Missing App Group container."]
            )
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).plist")
        let data = try PropertyListEncoder().encode(request)
        try data.write(to: file, options: [.atomic])
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            darwinNotificationName,
            nil,
            nil,
            true
        )
    }
}
