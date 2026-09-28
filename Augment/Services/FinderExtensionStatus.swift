import AppKit
import FinderSync

/// Whether Augment's Finder extension (right-click menu items, cut badge)
/// is switched on. macOS installs Finder Sync extensions turned *off*; the
/// user has to enable them in System Settings, which is the usual reason
/// the menu items "don't show up" on a new Mac.
enum FinderExtensionStatus {
    static var isEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    /// Opens System Settings exactly where the extension is switched on.
    static func openSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    private static let promptedKey = "augment.finderExtensionPrompted"

    /// Once per install: if a Finder feature is on but the extension is off,
    /// explain it and offer to open the right settings pane.
    @MainActor
    static func promptIfNeeded(preferences: SharedPreferences) {
        let wantsMenu = preferences.finderNewFileMenuEnabled || preferences.finderExtraMenuEnabled || preferences.fileCutPasteEnabled
        guard wantsMenu, !isEnabled, !UserDefaults.standard.bool(forKey: promptedKey) else { return }
        UserDefaults.standard.set(true, forKey: promptedKey)
        let alert = NSAlert()
        alert.messageText = Localizer.string("finderext.alert_title")
        alert.informativeText = Localizer.string("finderext.alert_body")
        alert.addButton(withTitle: Localizer.string("finderext.enable"))
        alert.addButton(withTitle: Localizer.string("finderext.later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }
}
