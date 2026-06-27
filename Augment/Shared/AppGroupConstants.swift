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
/// so keys and App Group file paths stay aligned. **Preferences in the group
/// suite are read/written only via `CFPreferences` + `kCFPreferencesCurrentUser`.**
/// Do not use `UserDefaults(suiteName:)` for `identifier` — it produces
/// `kCFPreferencesAnyUser` / cfprefsd detach logs and unreliable cross-process reads.
public enum AppGroup {
    /// The App Group identifier shared by every Augment target.
    ///
    /// This must match the value declared in each target's entitlements file
    /// under `com.apple.security.application-groups`.
    public static let identifier: String = "group.com.anilipeksumer.augment"

    private static let suiteDomain = identifier as CFString
    private static let suiteUser = kCFPreferencesCurrentUser
    private static let suiteHost = kCFPreferencesAnyHost

    /// Writes a property-list value into the App Group suite and flushes for
    /// cross-process visibility. Pass `nil` to remove the key.
    public static func setSuiteValue(_ value: CFPropertyList?, forKey key: String) {
        CFPreferencesSetValue(key as CFString, value, suiteDomain, suiteUser, suiteHost)
        synchronizeSuitePreferences()
    }

    /// Reads a value without synchronizing first — call `synchronizeSuitePreferences`
    /// before a batch of reads (e.g. `SharedPreferences.init`).
    public static func copySuiteValue(forKey key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, suiteDomain, suiteUser, suiteHost)
    }

    /// Sync the shared plist so another process’s writes are visible before we read.
    @discardableResult
    public static func synchronizeSuitePreferences() -> Bool {
        CFPreferencesSynchronize(suiteDomain, suiteUser, suiteHost)
    }

    /// Default values for each key in the App Group suite.
    public static let suiteRegistrationDefaults = PreferenceDefaults.registrationValues

    /// Reads a boolean for extensions / lightweight call sites using only
    /// `CFPreferences` + `kCFPreferencesCurrentUser` — never
    /// `UserDefaults(suiteName:)`, which logs `kCFPreferencesAnyUser` detach
    /// noise for App Group containers.
    public static func preferencesBool(forKey key: String) -> Bool {
        synchronizeSuitePreferences()
        return boolFromCopiedPlist(copySuiteValue(forKey: key))
            ?? (suiteRegistrationDefaults[key] as? Bool)
            ?? false
    }

    public static func preferencesDouble(forKey key: String) -> Double {
        synchronizeSuitePreferences()
        if let pref = copySuiteValue(forKey: key) as? Double { return pref }
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
    public static let minimizeEffect = "augment.minimizeEffect"

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
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("FinderCreateQueue", isDirectory: true)
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
        public init(filePath: String) { self.filePath = filePath }
    }

    public static var queueDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent("FinderRevealQueue", isDirectory: true)
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
