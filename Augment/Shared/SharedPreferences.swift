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

/// Action invoked when the user clicks the focused app's Dock icon.
public enum DockClickAction: String, CaseIterable, Identifiable, Codable {
    case toggleMinimize
    case closeAllWindows
    case quitApp
    case systemDefault

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toggleMinimize: return Localizer.string("click.toggle_minimize")
        case .closeAllWindows: return Localizer.string("click.close_all_windows")
        case .quitApp: return Localizer.string("click.quit_app")
        case .systemDefault: return Localizer.string("click.system_default")
        }
    }

    public var subtitle: String {
        switch self {
        case .toggleMinimize:
            return Localizer.string("click.toggle_minimize_subtitle")
        case .closeAllWindows:
            return Localizer.string("click.close_all_windows_subtitle")
        case .quitApp:
            return Localizer.string("click.quit_app_subtitle")
        case .systemDefault:
            return Localizer.string("click.system_default_subtitle")
        }
    }
}

/// Animation used by macOS when minimizing windows into the Dock.
///
/// Values map directly onto the `mineffect` key the Dock reads from
/// `com.apple.dock` user defaults, so persisting and applying the
/// preference is a 1:1 translation.
public enum DockMinimizeEffect: String, CaseIterable, Identifiable, Codable {
    /// Mirror whatever the system Dock currently has set – Augment will not
    /// override `mineffect`. This is the default so the app respects the
    /// macOS-wide animation choice.
    case system
    case genie
    case scale
    case suck

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return Localizer.string("effect.system")
        case .genie: return Localizer.string("effect.genie")
        case .scale: return Localizer.string("effect.scale")
        case .suck: return Localizer.string("effect.suck")
        }
    }

    public var subtitle: String {
        switch self {
        case .system: return Localizer.string("effect.system_subtitle")
        case .genie: return Localizer.string("effect.genie_subtitle")
        case .scale: return Localizer.string("effect.scale_subtitle")
        case .suck: return Localizer.string("effect.suck_subtitle")
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

    @Published public var minimizeEffect: DockMinimizeEffect {
        didSet { write(minimizeEffect.rawValue, AppGroupKey.minimizeEffect) }
    }

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

        let effectRaw = Self.loadString(AppGroupKey.minimizeEffect, reg) ?? DockMinimizeEffect.system.rawValue
        self.minimizeEffect = DockMinimizeEffect(rawValue: effectRaw) ?? .system

        self.lockedScreenIdentifiers = Self.loadStringArray(AppGroupKey.lockedScreenIDs, reg)

        // Window snapping
        self.windowSnappingEnabled = Self.loadBool(AppGroupKey.windowSnappingEnabled, reg)
        self.windowSnappingShortcuts = Self.loadString(AppGroupKey.windowSnappingShortcuts, reg) ?? ""

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
