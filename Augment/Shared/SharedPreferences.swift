import ApplicationServices
import Combine
import CoreFoundation
import Foundation

/// Visual size of the Dock hover preview panel.
///
/// Each case maps to a base thumbnail dimension; the rest of the preview
/// chrome (header, padding) scales proportionally. `standard` is the value
/// the panel shipped with originally and remains the default.
public enum PreviewPanelSize: String, CaseIterable, Identifiable, Codable {
    case small
    case standard
    case large

    public var id: String { rawValue }

    /// Width of a single window thumbnail cell in points.
    public var thumbnailWidth: CGFloat {
        switch self {
        case .small: return 156
        case .standard: return 200
        case .large: return 260
        }
    }

    /// Height of a single window thumbnail cell in points.
    public var thumbnailHeight: CGFloat {
        switch self {
        case .small: return 96
        case .standard: return 124
        case .large: return 162
        }
    }

    /// Magnified dimensions used when the user holds Space over the panel,
    /// mirroring the Finder Quick Look feel.
    public var magnifiedSize: CGSize {
        switch self {
        case .small: return CGSize(width: 520, height: 360)
        case .standard: return CGSize(width: 680, height: 440)
        case .large: return CGSize(width: 820, height: 540)
        }
    }

    /// Human-readable label shown in Settings.
    public var displayName: String {
        switch self {
        case .small: return Localizer.string("size.small")
        case .standard: return Localizer.string("size.standard")
        case .large: return Localizer.string("size.large")
        }
    }
}

/// Side of the thumbnail on which the macOS-style traffic-light cluster is
/// rendered. The opposite edge can host an optional destructive kill-app
/// button so right-handed and left-handed users can mirror the layout.
public enum TrafficLightSide: String, CaseIterable, Identifiable, Codable {
    case leading
    case trailing

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .leading: return Localizer.string("side.left")
        case .trailing: return Localizer.string("side.right")
        }
    }
}

/// Typed access to user preferences that live inside the App Group container.
///
/// The store is intentionally focused on app-surface options rather than
/// implementation knobs – every property here corresponds to a user-facing
/// switch or picker in the Augment Settings window.
public final class SharedPreferences: ObservableObject {
    /// Shared singleton used by the main app and any in-process consumers.
    public static let shared = SharedPreferences()

    /// Backup for `hasRequestedAccessibilityPrompt` if App Group plist is slow or unavailable
    /// (common during Xcode installs); prevents the Accessibility dialog every launch.
    private static let accessibilityPromptStandardKey = "com.anilipeksumer.augment.hasRequestedAccessibilityPrompt"

    // MARK: - Onboarding / permissions

    @Published public var didCompleteOnboarding: Bool {
        didSet { write(didCompleteOnboarding, AppGroupKey.didCompleteOnboarding) }
    }

    /// Whether Augment has shown the macOS Accessibility prompt at least
    /// once during this install. Prevents repeat prompts on every relaunch.
    @Published public var hasRequestedAccessibilityPrompt: Bool {
        didSet {
            write(hasRequestedAccessibilityPrompt, AppGroupKey.hasRequestedAccessibilityPrompt)
            UserDefaults.standard.set(hasRequestedAccessibilityPrompt, forKey: Self.accessibilityPromptStandardKey)
        }
    }

    // MARK: - Language

    @Published public var appLanguage: String {
        didSet { write(appLanguage, AppGroupKey.appLanguage) }
    }

    // MARK: - Master feature toggles

    @Published public var dockClickBehaviorEnabled: Bool {
        didSet { write(dockClickBehaviorEnabled, AppGroupKey.dockClickBehaviorEnabled) }
    }

    @Published public var windowPreviewsEnabled: Bool {
        didSet { write(windowPreviewsEnabled, AppGroupKey.windowPreviewsEnabled) }
    }

    @Published public var folderQuickLookEnabled: Bool {
        didSet { write(folderQuickLookEnabled, AppGroupKey.folderQuickLookEnabled) }
    }

    @Published public var folderQuickLookShowWarning: Bool {
        didSet { write(folderQuickLookShowWarning, AppGroupKey.folderQuickLookShowWarning) }
    }

    @Published public var finderNewFileMenuEnabled: Bool {
        didSet { write(finderNewFileMenuEnabled, AppGroupKey.finderNewFileMenuEnabled) }
    }

    @Published public var dockLockEnabled: Bool {
        didSet { write(dockLockEnabled, AppGroupKey.dockLockEnabled) }
    }

    // MARK: - Hover preview

    @Published public var hoverOpenDelay: Double {
        didSet { write(hoverOpenDelay, AppGroupKey.hoverOpenDelay) }
    }

    @Published public var previewSize: PreviewPanelSize {
        didSet { write(previewSize.rawValue, AppGroupKey.previewSize) }
    }

    @Published public var previewCloseButtonVisible: Bool {
        didSet { write(previewCloseButtonVisible, AppGroupKey.previewCloseButtonVisible) }
    }

    @Published public var headerActionsEnabled: Bool {
        didSet { write(headerActionsEnabled, AppGroupKey.headerActionsEnabled) }
    }

    @Published public var middleClickCloseEnabled: Bool {
        didSet { write(middleClickCloseEnabled, AppGroupKey.middleClickCloseEnabled) }
    }

    @Published public var dragOutEnabled: Bool {
        didSet { write(dragOutEnabled, AppGroupKey.dragOutEnabled) }
    }

    @Published public var spaceMagnifyEnabled: Bool {
        didSet { write(spaceMagnifyEnabled, AppGroupKey.spaceMagnifyEnabled) }
    }

    @Published public var suppressEmptyPreviews: Bool {
        didSet { write(suppressEmptyPreviews, AppGroupKey.suppressEmptyPreviews) }
    }

    /// When enabled, Dock hover may show the preview panel even if every window is minimized.
    @Published public var showHoverWhenMinimized: Bool {
        didSet { write(showHoverWhenMinimized, AppGroupKey.showHoverWhenMinimized) }
    }

    // MARK: - Window controls

    @Published public var trafficLightEnabled: Bool {
        didSet { write(trafficLightEnabled, AppGroupKey.trafficLightEnabled) }
    }

    @Published public var trafficLightSide: TrafficLightSide {
        didSet { write(trafficLightSide.rawValue, AppGroupKey.trafficLightSide) }
    }

    @Published public var killButtonVisible: Bool {
        didSet { write(killButtonVisible, AppGroupKey.killButtonVisible) }
    }

    // MARK: - Minimize effect

    // MARK: - Multi-display dock lock

    /// User-selected screens that the dock interaction stays anchored to.
    /// Stored as `localizedName + ":" + displayID` joined with commas so we
    /// can survive screen reconfiguration without sticking to a stale ID.
    @Published public var lockedScreenIdentifiers: [String] {
        didSet { write(lockedScreenIdentifiers, AppGroupKey.lockedScreenIDs) }
    }

    // MARK: - Window snapping

    /// Master toggle for Cmd+Arrow window snapping.
    @Published public var windowSnappingEnabled: Bool {
        didSet { write(windowSnappingEnabled, AppGroupKey.windowSnappingEnabled) }
    }

    /// JSON-encoded shortcut overrides for each snap direction.
    /// Format: `{"left": {"modifiers": 1048576, "keyCode": 123}, ...}`
    /// When empty/nil, defaults to Cmd+Arrow keys.
    @Published public var windowSnappingShortcuts: String {
        didSet { write(windowSnappingShortcuts, AppGroupKey.windowSnappingShortcuts) }
    }

    // MARK: - Window cut & paste

    /// Master toggle for ⌃⌘X (cut focused window) / ⌃⌘V (paste it under the cursor).
    @Published public var windowCutPasteEnabled: Bool {
        didSet { write(windowCutPasteEnabled, AppGroupKey.windowCutPasteEnabled) }
    }

    // MARK: - File cut & paste

    /// Master toggle for a real Finder "Cut" via ⌘X / ⌘V.
    @Published public var fileCutPasteEnabled: Bool {
        didSet { write(fileCutPasteEnabled, AppGroupKey.fileCutPasteEnabled) }
    }

    // MARK: - Snap Layouts

    /// Master toggle for the ⌃⌥Space snap-zone picker.
    @Published public var snapLayoutsEnabled: Bool {
        didSet { write(snapLayoutsEnabled, AppGroupKey.snapLayoutsEnabled) }
    }

    // MARK: - Window switcher

    /// Master toggle for the ⌥Tab thumbnail window switcher.
    @Published public var windowSwitcherEnabled: Bool {
        didSet { write(windowSwitcherEnabled, AppGroupKey.windowSwitcherEnabled) }
    }

    // MARK: - Menu bar organizer

    // MARK: - Volume mixer

    /// Master toggle for the per-app volume mixer.
    @Published public var volumeMixerEnabled: Bool {
        didSet { write(volumeMixerEnabled, AppGroupKey.volumeMixerEnabled) }
    }

    // MARK: - External display control

    // MARK: - Notch (BoringNotch)

    /// Master toggle for the interactive notch overlay.
    @Published public var notchEnabled: Bool {
        didSet { write(notchEnabled, AppGroupKey.notchEnabled) }
    }

    /// Whether the music widget is shown inside the notch.
    @Published public var notchMusicWidget: Bool {
        didSet { write(notchMusicWidget, AppGroupKey.notchMusicWidget) }
    }

    /// Whether the battery indicator is shown inside the notch.
    @Published public var notchBatteryWidget: Bool {
        didSet { write(notchBatteryWidget, AppGroupKey.notchBatteryWidget) }
    }

    /// Whether the file shelf is shown inside the notch.
    @Published public var notchShelfWidget: Bool {
        didSet { write(notchShelfWidget, AppGroupKey.notchShelfWidget) }
    }

    /// Whether playback controls are shown for media.
    @Published public var notchMediaControlsEnabled: Bool {
        didSet { write(notchMediaControlsEnabled, AppGroupKey.notchMediaControlsEnabled) }
    }

    /// Whether the source app icon is shown for media.
    @Published public var notchShowAppIcon: Bool {
        didSet { write(notchShowAppIcon, AppGroupKey.notchShowAppIcon) }
    }

    /// Whether album art is shown for media.
    @Published public var notchShowAlbumArt: Bool {
        didSet { write(notchShowAlbumArt, AppGroupKey.notchShowAlbumArt) }
    }

    /// Whether the calendar widget is shown.
    @Published public var notchCalendarEnabled: Bool {
        didSet { write(notchCalendarEnabled, AppGroupKey.notchCalendarEnabled) }
    }

    @Published public var notchCalendarStyle: String {
        didSet { write(notchCalendarStyle, AppGroupKey.notchCalendarStyle) }
    }

    @Published public var notchBatteryStyle: String {
        didSet { write(notchBatteryStyle, AppGroupKey.notchBatteryStyle) }
    }

    /// Delay in seconds before the notch expands on hover.
    @Published public var notchHoverDelay: Double {
        didSet { write(notchHoverDelay, AppGroupKey.notchHoverDelay) }
    }

    /// Persisted pinned URLs for the file shelf
    @Published public var notchShelfURLs: [String] {
        didSet { write(notchShelfURLs, AppGroupKey.notchShelfURLs) }
    }

    /// Master toggle for the clipboard history feature.
    @Published public var clipboardHistoryEnabled: Bool {
        didSet { write(clipboardHistoryEnabled, AppGroupKey.clipboardHistoryEnabled) }
    }

    /// Whether the keep-awake toggle button is shown in the notch top bar.
    @Published public var notchCaffeinateWidget: Bool {
        didSet { write(notchCaffeinateWidget, AppGroupKey.notchCaffeinateWidget) }
    }

    /// Whether the quick note + Pomodoro timer widget is shown.
    @Published public var displayKeysEnabled: Bool {
        didSet { write(displayKeysEnabled, AppGroupKey.displayKeysEnabled) }
    }
    @Published public var brightnessScheduleEnabled: Bool {
        didSet { write(brightnessScheduleEnabled, AppGroupKey.brightnessScheduleEnabled) }
    }
    @Published public var brightnessDayStart: Double {
        didSet { write(brightnessDayStart, AppGroupKey.brightnessDayStart) }
    }
    @Published public var brightnessNightStart: Double {
        didSet { write(brightnessNightStart, AppGroupKey.brightnessNightStart) }
    }
    @Published public var brightnessDayLevel: Double {
        didSet { write(brightnessDayLevel, AppGroupKey.brightnessDayLevel) }
    }
    @Published public var brightnessNightLevel: Double {
        didSet { write(brightnessNightLevel, AppGroupKey.brightnessNightLevel) }
    }
    @Published public var awakeDisplayMaySleep: Bool {
        didSet { write(awakeDisplayMaySleep, AppGroupKey.awakeDisplayMaySleep) }
    }
    @Published public var awakeWhileApps: [String] {
        didSet { write(awakeWhileApps, AppGroupKey.awakeWhileApps) }
    }
    @Published public var awakeOnPower: Bool {
        didSet { write(awakeOnPower, AppGroupKey.awakeOnPower) }
    }
    @Published public var awakeWhileDownloading: Bool {
        didSet { write(awakeWhileDownloading, AppGroupKey.awakeWhileDownloading) }
    }
    @Published public var awakeLidClosed: Bool {
        didSet { write(awakeLidClosed, AppGroupKey.awakeLidClosed) }
    }
    @Published public var clipboardPanelEnabled: Bool {
        didSet { write(clipboardPanelEnabled, AppGroupKey.clipboardPanelEnabled) }
    }
    @Published public var meetingsEnabled: Bool {
        didSet { write(meetingsEnabled, AppGroupKey.meetingsEnabled) }
    }
    @Published public var screenshotShelfEnabled: Bool {
        didSet { write(screenshotShelfEnabled, AppGroupKey.screenshotShelfEnabled) }
    }
    @Published public var finderExtraMenuEnabled: Bool {
        didSet { write(finderExtraMenuEnabled, AppGroupKey.finderExtraMenuEnabled) }
    }
    @Published public var quickPanelDisplays: Bool {
        didSet { write(quickPanelDisplays, AppGroupKey.quickPanelDisplays) }
    }
    @Published public var quickPanelSound: Bool {
        didSet { write(quickPanelSound, AppGroupKey.quickPanelSound) }
    }
    @Published public var quickPanelMic: Bool {
        didSet { write(quickPanelMic, AppGroupKey.quickPanelMic) }
    }
    @Published public var quickPanelMeetings: Bool {
        didSet { write(quickPanelMeetings, AppGroupKey.quickPanelMeetings) }
    }
    @Published public var quickPanelAwake: Bool {
        didSet { write(quickPanelAwake, AppGroupKey.quickPanelAwake) }
    }
    @Published public var notchMirrorEnabled: Bool {
        didSet { write(notchMirrorEnabled, AppGroupKey.notchMirrorEnabled) }
    }
    @Published public var notchPomodoroMinutes: Double {
        didSet { write(notchPomodoroMinutes, AppGroupKey.notchPomodoroMinutes) }
    }
    @Published public var notchProductivityWidget: Bool {
        didSet { write(notchProductivityWidget, AppGroupKey.notchProductivityWidget) }
    }

    /// Persisted text of the notch quick-note scratchpad.
    @Published public var notchQuickNoteText: String {
        didSet { write(notchQuickNoteText, AppGroupKey.notchQuickNoteText) }
    }

    // MARK: - Init

    public init() {
        AppGroup.synchronizeSuitePreferences()
        let reg = PreferenceDefaults.registrationValues

        self.didCompleteOnboarding = Self.loadBool(AppGroupKey.didCompleteOnboarding, reg)
        self.appLanguage = Self.loadString(AppGroupKey.appLanguage, reg) ?? "system"
        let suitePrompt = Self.loadBool(AppGroupKey.hasRequestedAccessibilityPrompt, reg)
        let stdPrompt = UserDefaults.standard.bool(forKey: Self.accessibilityPromptStandardKey)
        self.hasRequestedAccessibilityPrompt = suitePrompt || stdPrompt
        self.dockClickBehaviorEnabled = Self.loadBool(AppGroupKey.dockClickBehaviorEnabled, reg)
        self.windowPreviewsEnabled = Self.loadBool(AppGroupKey.windowPreviewsEnabled, reg)
        self.folderQuickLookEnabled = Self.loadBool(AppGroupKey.folderQuickLookEnabled, reg)
        self.folderQuickLookShowWarning = Self.loadBool(AppGroupKey.folderQuickLookShowWarning, reg)
        self.finderNewFileMenuEnabled = Self.loadBool(AppGroupKey.finderNewFileMenuEnabled, reg)
        self.dockLockEnabled = Self.loadBool(AppGroupKey.dockLockEnabled, reg)

        let storedDelay = Self.loadDouble(AppGroupKey.hoverOpenDelay, reg)
        self.hoverOpenDelay = SharedPreferences.clampHoverDelay(storedDelay)

        let sizeRaw = Self.loadString(AppGroupKey.previewSize, reg) ?? PreviewPanelSize.standard.rawValue
        self.previewSize = PreviewPanelSize(rawValue: sizeRaw) ?? .standard

        self.previewCloseButtonVisible = Self.loadBool(AppGroupKey.previewCloseButtonVisible, reg)
        self.headerActionsEnabled = Self.loadBool(AppGroupKey.headerActionsEnabled, reg)
        self.middleClickCloseEnabled = Self.loadBool(AppGroupKey.middleClickCloseEnabled, reg)
        self.dragOutEnabled = Self.loadBool(AppGroupKey.dragOutEnabled, reg)
        self.spaceMagnifyEnabled = Self.loadBool(AppGroupKey.spaceMagnifyEnabled, reg)
        self.suppressEmptyPreviews = Self.loadBool(AppGroupKey.suppressEmptyPreviews, reg)
        self.showHoverWhenMinimized = Self.loadBool(AppGroupKey.showHoverWhenMinimized, reg)

        self.trafficLightEnabled = Self.loadBool(AppGroupKey.trafficLightEnabled, reg)
        let sideRaw = Self.loadString(AppGroupKey.trafficLightSide, reg) ?? TrafficLightSide.trailing.rawValue
        self.trafficLightSide = TrafficLightSide(rawValue: sideRaw) ?? .trailing
        self.killButtonVisible = Self.loadBool(AppGroupKey.killButtonVisible, reg)


        self.lockedScreenIdentifiers = Self.loadStringArray(AppGroupKey.lockedScreenIDs, reg)

        // Window snapping
        self.windowSnappingEnabled = Self.loadBool(AppGroupKey.windowSnappingEnabled, reg)
        self.windowSnappingShortcuts = Self.loadString(AppGroupKey.windowSnappingShortcuts, reg) ?? ""

        self.windowCutPasteEnabled = Self.loadBool(AppGroupKey.windowCutPasteEnabled, reg)
        self.fileCutPasteEnabled = Self.loadBool(AppGroupKey.fileCutPasteEnabled, reg)
        self.snapLayoutsEnabled = Self.loadBool(AppGroupKey.snapLayoutsEnabled, reg)
        self.windowSwitcherEnabled = Self.loadBool(AppGroupKey.windowSwitcherEnabled, reg)
        self.volumeMixerEnabled = Self.loadBool(AppGroupKey.volumeMixerEnabled, reg)

        // Notch
        self.notchEnabled = Self.loadBool(AppGroupKey.notchEnabled, reg)
        self.notchMusicWidget = Self.loadBool(AppGroupKey.notchMusicWidget, reg)
        self.notchBatteryWidget = Self.loadBool(AppGroupKey.notchBatteryWidget, reg)
        self.notchShelfWidget = Self.loadBool(AppGroupKey.notchShelfWidget, reg)
        self.notchMediaControlsEnabled = Self.loadBool(AppGroupKey.notchMediaControlsEnabled, reg)
        self.notchShowAppIcon = Self.loadBool(AppGroupKey.notchShowAppIcon, reg)
        self.notchShowAlbumArt = Self.loadBool(AppGroupKey.notchShowAlbumArt, reg)
        self.notchCalendarEnabled = Self.loadBool(AppGroupKey.notchCalendarEnabled, reg)
        self.notchCalendarStyle = Self.loadString(AppGroupKey.notchCalendarStyle, reg) ?? "compact"
        self.notchBatteryStyle = Self.loadString(AppGroupKey.notchBatteryStyle, reg) ?? "gauge"
        self.notchHoverDelay = Self.loadDouble(AppGroupKey.notchHoverDelay, reg)
        self.notchShelfURLs = Self.loadStringArray(AppGroupKey.notchShelfURLs, reg)
        self.clipboardHistoryEnabled = Self.loadBool(AppGroupKey.clipboardHistoryEnabled, reg)
        self.notchCaffeinateWidget = Self.loadBool(AppGroupKey.notchCaffeinateWidget, reg)
        self.notchProductivityWidget = Self.loadBool(AppGroupKey.notchProductivityWidget, reg)
        self.notchPomodoroMinutes = Self.loadDouble(AppGroupKey.notchPomodoroMinutes, reg)
        self.notchMirrorEnabled = Self.loadBool(AppGroupKey.notchMirrorEnabled, reg)
        self.quickPanelDisplays = Self.loadBool(AppGroupKey.quickPanelDisplays, reg)
        self.quickPanelSound = Self.loadBool(AppGroupKey.quickPanelSound, reg)
        self.quickPanelMic = Self.loadBool(AppGroupKey.quickPanelMic, reg)
        self.quickPanelMeetings = Self.loadBool(AppGroupKey.quickPanelMeetings, reg)
        self.quickPanelAwake = Self.loadBool(AppGroupKey.quickPanelAwake, reg)
        self.displayKeysEnabled = Self.loadBool(AppGroupKey.displayKeysEnabled, reg)
        self.brightnessScheduleEnabled = Self.loadBool(AppGroupKey.brightnessScheduleEnabled, reg)
        self.brightnessDayStart = Self.loadDouble(AppGroupKey.brightnessDayStart, reg)
        self.brightnessNightStart = Self.loadDouble(AppGroupKey.brightnessNightStart, reg)
        self.brightnessDayLevel = Self.loadDouble(AppGroupKey.brightnessDayLevel, reg)
        self.brightnessNightLevel = Self.loadDouble(AppGroupKey.brightnessNightLevel, reg)
        self.awakeDisplayMaySleep = Self.loadBool(AppGroupKey.awakeDisplayMaySleep, reg)
        self.awakeWhileApps = Self.loadStringArray(AppGroupKey.awakeWhileApps, reg)
        self.awakeOnPower = Self.loadBool(AppGroupKey.awakeOnPower, reg)
        self.awakeWhileDownloading = Self.loadBool(AppGroupKey.awakeWhileDownloading, reg)
        self.awakeLidClosed = Self.loadBool(AppGroupKey.awakeLidClosed, reg)
        self.clipboardPanelEnabled = Self.loadBool(AppGroupKey.clipboardPanelEnabled, reg)
        self.meetingsEnabled = Self.loadBool(AppGroupKey.meetingsEnabled, reg)
        self.screenshotShelfEnabled = Self.loadBool(AppGroupKey.screenshotShelfEnabled, reg)
        self.finderExtraMenuEnabled = Self.loadBool(AppGroupKey.finderExtraMenuEnabled, reg)
        self.notchQuickNoteText = Self.loadString(AppGroupKey.notchQuickNoteText, reg) ?? ""
    }

    private static func loadBool(_ key: String, _ registration: [String: Any]) -> Bool {
        guard let o = AppGroup.copySuiteValue(forKey: key) else {
            return registration[key] as? Bool ?? false
        }
        if let b = o as? Bool { return b }
        if let n = o as? NSNumber { return n.boolValue }
        return registration[key] as? Bool ?? false
    }

    private static func loadDouble(_ key: String, _ registration: [String: Any]) -> Double {
        if let o = AppGroup.copySuiteValue(forKey: key) as? NSNumber {
            return o.doubleValue
        }
        return registration[key] as? Double ?? 0.4
    }

    private static func loadString(_ key: String, _ registration: [String: Any]) -> String? {
        if let s = AppGroup.copySuiteValue(forKey: key) as? String {
            return s
        }
        return registration[key] as? String
    }

    private static func loadStringArray(_ key: String, _ registration: [String: Any]) -> [String] {
        let raw = AppGroup.copySuiteValue(forKey: key)
        if let a = raw as? [String] {
            return a
        }
        if let a = raw as? NSArray {
            return a.compactMap { $0 as? String }
        }
        return registration[key] as? [String] ?? []
    }

    /// Allowed range for `hoverOpenDelay` in seconds. Anything outside this
    /// range is clamped on load to prevent broken stored values from making
    /// the panel feel either flickery or unresponsive.
    public static let hoverDelayRange: ClosedRange<Double> = 0.0...1.5

    public static func clampHoverDelay(_ value: Double) -> Double {
        max(hoverDelayRange.lowerBound, min(hoverDelayRange.upperBound, value))
    }

    /// Reads a fresh value for a master toggle straight from the App Group
    /// container, bypassing the in-memory `@Published` cache.
    ///
    /// Extensions like `AugmentFinder` and `AugmentQL` run in their own
    /// processes; they only see the value of `@Published` properties at the
    /// time `SharedPreferences` was first created in their address space.
    /// Without this helper, toggling a feature off and on in the main app
    /// would not affect the extension's behavior until the host (Finder /
    /// QuickLook) re-instantiated the extension.
    public func currentBool(forKey key: String) -> Bool {
        AppGroup.preferencesBool(forKey: key)
    }

    /// Call when Accessibility is already granted so the guard flag matches reality across reinstall/debug cycles.
    public func syncAccessibilityPromptFlagIfProcessTrusted() {
        guard AXIsProcessTrusted() else { return }
        if !hasRequestedAccessibilityPrompt {
            hasRequestedAccessibilityPrompt = true
        }
    }

    /// Cross-process flush for the App Group preference container.
    ///
    /// `CFPreferencesAppSynchronize` would implicitly use
    /// `kCFPreferencesAnyUser`, which cfprefsd refuses for App Group
    /// containers and surfaces as the noisy "Using kCFPreferencesAnyUser
    /// with a container is only allowed for System Containers" warning.
    /// Targeting `kCFPreferencesCurrentUser` + `kCFPreferencesAnyHost` is
    /// what Apple's sample code uses for App Group plists and is silent.
    public static func synchronizeAppGroup() {
        AppGroup.synchronizeSuitePreferences()
    }

    // MARK: - Persistence helper

    /// All writes funnel through `CFPreferences` with `kCFPreferencesCurrentUser`
    /// so we never touch `UserDefaults(suiteName:)`, which triggers the
    /// `kCFPreferencesAnyUser` / cfprefsd detach warning for App Groups.
    private func write<T>(_ value: T, _ key: String) {
        let plist: CFPropertyList?
        switch value {
        case let b as Bool:
            plist = NSNumber(value: b)
        case let d as Double:
            plist = NSNumber(value: d)
        case let s as String:
            plist = s as NSString
        case let a as [String]:
            plist = a as NSArray
        default:
            plist = nil
        }
        AppGroup.setSuiteValue(plist, forKey: key)
    }
}
