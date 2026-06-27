import AppKit
import Foundation

enum MediaScriptRunner {
    private static let processTimeout: TimeInterval = 3.0

    static func string(_ source: String) -> String? {
        if let s = runViaOsascript(source), !s.isEmpty { return s }
        return nil
    }

    static func data(_ source: String) -> Data? {
        _ = source
        // Avoid NSAppleScript here: it has no cancellation/timeout surface and
        // can pin an Automation thread if a target app stops responding.
        return nil
    }

    private static func runViaOsascript(_ source: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-l", "AppleScript", "-"]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = Pipe()
        let group = DispatchGroup()
        group.enter()
        task.terminationHandler = { _ in group.leave() }
        do {
            try task.run()
            if let data = source.data(using: .utf8) {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try stdinPipe.fileHandleForWriting.close()

            if group.wait(timeout: .now() + processTimeout) == .timedOut {
                task.terminate()
                return nil
            }

            let out = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
            guard task.terminationStatus == 0 else { return nil }
            let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false) ? text : nil
        } catch {
            return nil
        }
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
