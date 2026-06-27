import AppKit
import Foundation

/// Applies the user's chosen Dock minimize animation by writing the
/// `mineffect` key into `com.apple.dock` preferences and restarting the
/// Dock so the change takes effect.
///
/// macOS reads `mineffect` only at Dock launch, so changing it without
/// relaunching the Dock has no visible result. The relaunch happens via
/// `killall Dock`; launchd brings the Dock back automatically within a
/// fraction of a second. The `system` case does nothing – Augment leaves
/// macOS's choice alone, which the user explicitly asked for so we stop
/// fighting the system-wide preference.
enum DockEffectApplier {

    static func apply(_ effect: DockMinimizeEffect) {
        guard effect != .system else { return }

        let dockDomain = "com.apple.dock" as CFString
        let key = "mineffect" as CFString

        let current = CFPreferencesCopyAppValue(key, dockDomain) as? String
        if current == effect.rawValue { return }

        CFPreferencesSetAppValue(key, effect.rawValue as CFString, dockDomain)
        CFPreferencesAppSynchronize(dockDomain)

        relaunchDock()
    }

    private static func relaunchDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        do {
            try task.run()
        } catch {
            NSLog("Augment: failed to relaunch Dock: \(error.localizedDescription)")
        }
    }
}

