import AppKit
import ApplicationServices
import CoreGraphics

/// A macOS privacy permission some Augment feature depends on.
enum FeaturePermission: Hashable {
    case accessibility
    case screenRecording
    case automation(bundleID: String)

    static let finderAutomation = FeaturePermission.automation(bundleID: "com.apple.finder")

    var title: String {
        switch self {
        case .accessibility: return Localizer.string("perm.accessibility")
        case .screenRecording: return Localizer.string("perm.screen_recording")
        case .automation: return Localizer.string("perm.automation_finder")
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility:
            return AXIsProcessTrusted()
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .automation(let bundleID):
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr
        }
    }

    /// Shows the system consent prompt when macOS still allows one, otherwise
    /// opens the matching System Settings pane (e.g. after an earlier "Don't
    /// Allow", which macOS never re-asks on its own).
    func request() {
        switch self {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) { openSettings() }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings() }
        case .automation(let bundleID):
            // Blocks until the user answers, so keep it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
                if status == OSStatus(errAEEventNotPermitted) {
                    DispatchQueue.main.async { self.openSettings() }
                }
            }
        }
    }

    func openSettings() {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .automation: anchor = "Privacy_Automation"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Which permissions each opt-in feature needs. Nothing is requested at
/// launch — only when the user switches the matching feature on.
enum FeatureRequirements {
    static func permissions(forPreferenceKey key: String) -> [FeaturePermission] {
        switch key {
        case AppGroupKey.windowPreviewsEnabled, AppGroupKey.windowSwitcherEnabled:
            return [.accessibility, .screenRecording]
        case AppGroupKey.dockClickBehaviorEnabled,
             AppGroupKey.windowSnappingEnabled,
             AppGroupKey.windowCutPasteEnabled,
             AppGroupKey.snapLayoutsEnabled,
             AppGroupKey.displayKeysEnabled,
             AppGroupKey.clipboardPanelEnabled:
            return [.accessibility]
        case AppGroupKey.fileCutPasteEnabled:
            return [.accessibility, .finderAutomation]
        default:
            return []
        }
    }

    /// Requests whatever is still missing, one prompt at a time.
    static func requestMissing(forPreferenceKey key: String) {
        permissions(forPreferenceKey: key).first { !$0.isGranted }?.request()
    }
}
