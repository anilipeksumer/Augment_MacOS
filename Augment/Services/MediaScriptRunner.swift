import AppKit
import Foundation

enum MediaScriptRunner {
    private static let scriptTimeout: TimeInterval = 3.0

    static func string(_ source: String) -> String? {
        guard let value = run(source)?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    /// Raw binary result of a script, e.g. `data of artwork 1` for embedded
    /// album art. `NSAppleScript` hands this back as a proper `Data` blob on
    /// the descriptor — no hex/`«data JPEGxxxx»` text parsing required, which
    /// is what made this unusable through the old `osascript` subprocess.
    static func data(_ source: String) -> Data? {
        run(source)?.data
    }

    /// Runs AppleScript in-process via `NSAppleScript` rather than spawning
    /// `/usr/bin/osascript` per call. Two benefits: it drops the process-spawn
    /// churn from polling several media apps every few seconds, and it keeps
    /// Automation TCC attribution tied directly to Augment's own signed
    /// process instead of an intermediary subprocess.
    ///
    /// `executeAndReturnError` is synchronous with no native cancellation, so
    /// a target app that stops responding could otherwise pin the calling
    /// thread indefinitely. Each call runs on its own dispatch work item
    /// (never a shared serial queue) and is abandoned past the timeout
    /// instead of awaited — a hang leaks one background thread rather than
    /// blocking every future call behind it.
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        let group = DispatchGroup()
        group.enter()
        var result: NSAppleEventDescriptor?
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            result = script.executeAndReturnError(&errorInfo)
            group.leave()
        }
        return group.wait(timeout: .now() + scriptTimeout) == .success ? result : nil
    }
}

enum MediaInfoFactory {
    static func displayName(forBundleID id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func icon(forBundleID id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func make(
        bundleID: String,
        title: String,
        subtitle: String,
        playing: Bool,
        duration: Double? = nil,
        elapsedTime: Double? = nil,
        art: NSImage? = nil,
        isJSDisabled: Bool = false
    ) -> MediaInfo {
        MediaInfo(
            title: title,
            artist: subtitle,
            appName: displayName(forBundleID: bundleID) ?? bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID,
            appIcon: icon(forBundleID: bundleID),
            albumArt: art,
            isPlaying: playing,
            duration: duration,
            elapsedTime: elapsedTime,
            appBundleID: bundleID,
            isJSDisabled: isJSDisabled
        )
    }

    static func isAppRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func parseDouble(_ string: String) -> Double? {
        let cleaned = string.replacingOccurrences(of: ",", with: ".")
        return Double(cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
