import AppKit
import Foundation

enum MediaCommandSender {
    private static let commandQueue = DispatchQueue(
        label: "com.anilipeksumer.augment.media-command",
        qos: .userInitiated
    )

    static func sendCommand(
        _ command: String,
        bundleID: String?,
        fallbackAppName: String?,
        currentMedia: MediaInfo?,
        completion: @escaping () -> Void
    ) {
        commandQueue.async {
            sendCommandSync(command, bundleID: bundleID, fallbackAppName: fallbackAppName, currentMedia: currentMedia)
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func seekToTime(
        _ time: Double,
        bundleID: String?,
        fallbackAppName: String?,
        completion: @escaping () -> Void
    ) {
        commandQueue.async {
            seekToTimeSync(time, bundleID: bundleID, fallbackAppName: fallbackAppName)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func sendCommandSync(_ command: String, bundleID: String?, fallbackAppName: String?, currentMedia: MediaInfo?) {
        let lowered = command.lowercased()

        // For JS-disabled sources, use media keys exclusively
        if currentMedia?.isJSDisabled == true {
            let mediaKey: Int32?
            switch lowered {
            case "play", "pause", "playpause": mediaKey = 16
            case "next track": mediaKey = 17
            case "previous track": mediaKey = 18
            default: mediaKey = nil
            }
            if let mediaKey {
                simulateMediaKey(mediaKey)
                return
            }
        }

        // Try AppleScript control first
        appleScriptControl(command: lowered, bundleID: bundleID, fallbackAppName: fallbackAppName)

        // For play/pause/next/prev, also simulate the system media key as
        // a belt-and-braces fallback. This handles apps that don't respond
        // to AppleScript (e.g. YouTube in a browser with no extension, or
        // generic media apps). The media key is idempotent with the
        // AppleScript command for well-behaved players.
        if bundleID == nil && fallbackAppName == nil {
            let mediaKey: Int32?
            switch lowered {
            case "play", "pause", "playpause": mediaKey = 16
            case "next track": mediaKey = 17
            case "previous track": mediaKey = 18
            default: mediaKey = nil
            }
            if let mediaKey {
                simulateMediaKey(mediaKey)
            }
        }
    }

    private static func seekToTimeSync(_ time: Double, bundleID: String?, fallbackAppName: String?) {
        let bid = bundleID ?? ""
        let vlc = bid == "org.videolan.vlc" || (fallbackAppName?.localizedCaseInsensitiveContains("vlc") ?? false)

        if !bid.isEmpty {
            if BrowserMediaProvider.isBrowser(bundleID: bid) {
                BrowserMediaProvider.seek(to: time, bundleID: bid)
                return
            }
            if vlc {
                _ = MediaScriptRunner.string("try\ntell application id \"org.videolan.vlc\"\nset current time to \(time)\nend tell\nend try")
                return
            }
            if bid == "com.spotify.client" {
                _ = MediaScriptRunner.string("try\ntell application id \"com.spotify.client\"\nset player position to \(time)\nend tell\nend try")
                return
            }
            if bid == "com.apple.Music" {
                _ = MediaScriptRunner.string("try\ntell application id \"com.apple.Music\"\nset player position to \(time)\nend tell\nend try")
                return
            }
        }

        guard let name = fallbackAppName, !name.isEmpty else { return }
        if vlc {
            _ = MediaScriptRunner.string("try\ntell application \"VLC\"\nset current time to \(time)\nend tell\nend try")
            return
        }
        if name.localizedCaseInsensitiveContains("spotify") {
            _ = MediaScriptRunner.string("try\ntell application \"Spotify\"\nset player position to \(time)\nend tell\nend try")
            return
        }
        if name.localizedCaseInsensitiveContains("music") {
            _ = MediaScriptRunner.string("try\ntell application \"Music\"\nset player position to \(time)\nend tell\nend try")
        }
    }

    private static func simulateMediaKey(_ key: Int32) {
        DispatchQueue.main.async {
            postMediaKey(key)
        }
    }

    private static func postMediaKey(_ key: Int32) {
        let keyFlags = (key << 16) | (0xA << 8)
        let keyDown = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(keyFlags),
            data2: -1
        )

        let keyUpFlags = (key << 16) | (0xB << 8)
        let keyUp = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: Int(keyUpFlags),
            data2: -1
        )

        keyDown?.cgEvent?.post(tap: .cghidEventTap)
        keyUp?.cgEvent?.post(tap: .cghidEventTap)
    }

    private static func appleScriptControl(command: String, bundleID: String?, fallbackAppName: String?) {
        let bid = bundleID ?? ""
        let vlc = bid == "org.videolan.vlc" || (fallbackAppName?.localizedCaseInsensitiveContains("vlc") ?? false)

        if !bid.isEmpty {
            if BrowserMediaProvider.isBrowser(bundleID: bid) {
                BrowserMediaProvider.control(command: command, bundleID: bid)
                return
            }
            if vlc, runVLCCommand(command, byBundleID: true) { return }
            if bid == "com.spotify.client", runSeekablePlayerCommand(command, bundleID: bid, appKind: .spotify) { return }
            if bid == "com.apple.Music", runSeekablePlayerCommand(command, bundleID: bid, appKind: .music) { return }

            if let verb = appleVerb(for: command, vlc: vlc) {
                _ = MediaScriptRunner.string("tell application id \"\(bid)\" to \(verb)")
                return
            }
        }

        guard let name = fallbackAppName, !name.isEmpty else { return }
        if vlc, runVLCCommand(command, byBundleID: false) { return }
        if name.localizedCaseInsensitiveContains("spotify"),
           runSeekableNamedPlayerCommand(command, appName: "Spotify", appKind: .spotify) { return }
        if name.localizedCaseInsensitiveContains("music"),
           runSeekableNamedPlayerCommand(command, appName: "Music", appKind: .music) { return }

        if let verb = appleVerb(for: command, vlc: vlc) {
            let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
            _ = MediaScriptRunner.string("tell application \"\(escaped)\" to \(verb)")
        }
    }

    private static func runVLCCommand(_ command: String, byBundleID: Bool) -> Bool {
        let target = byBundleID ? "application id \"org.videolan.vlc\"" : "application \"VLC\""
        switch command {
        case "playpause":
            _ = MediaScriptRunner.string("try\ntell \(target)\nif playing then pause else play\nend tell\nend try")
        case "seek_backward":
            _ = MediaScriptRunner.string("try\ntell \(target)\nset pos to current time\nset current time to (pos - 10)\nend tell\nend try")
        case "seek_forward":
            _ = MediaScriptRunner.string("try\ntell \(target)\nset pos to current time\nset current time to (pos + 10)\nend tell\nend try")
        default:
            return false
        }
        return true
    }

    private enum SeekableAppKind {
        case spotify
        case music
    }

    private static func runSeekablePlayerCommand(_ command: String, bundleID: String, appKind: SeekableAppKind) -> Bool {
        runSeekableCommand(command, target: "application id \"\(bundleID)\"", appKind: appKind)
    }

    private static func runSeekableNamedPlayerCommand(_ command: String, appName: String, appKind: SeekableAppKind) -> Bool {
        runSeekableCommand(command, target: "application \"\(appName)\"", appKind: appKind)
    }

    private static func runSeekableCommand(_ command: String, target: String, appKind: SeekableAppKind) -> Bool {
        switch command {
        case "play":
            _ = MediaScriptRunner.string("try\ntell \(target)\nplay\nend tell\nend try")
        case "pause":
            _ = MediaScriptRunner.string("try\ntell \(target)\npause\nend tell\nend try")
        case "playpause":
            _ = MediaScriptRunner.string(playPauseScript(target: target, appKind: appKind))
        case "next track":
            _ = MediaScriptRunner.string("try\ntell \(target)\nnext track\nend tell\nend try")
        case "previous track":
            _ = MediaScriptRunner.string("try\ntell \(target)\nprevious track\nend tell\nend try")
        case "seek_backward":
            _ = MediaScriptRunner.string("try\ntell \(target)\nset pos to player position\nset player position to (pos - 10)\nend tell\nend try")
        case "seek_forward":
            _ = MediaScriptRunner.string("try\ntell \(target)\nset pos to player position\nset player position to (pos + 10)\nend tell\nend try")
        default:
            return false
        }
        return true
    }

    private static func playPauseScript(target: String, appKind: SeekableAppKind) -> String {
        switch appKind {
        case .spotify:
            return """
            try
            tell \(target)
            if player state is playing then
            pause
            else
            play
            end if
            end tell
            end try
            """
        case .music:
            return """
            try
            tell \(target)
            if player state is playing then
            pause
            else
            play
            end if
            end tell
            end try
            """
        }
    }

    private static func appleVerb(for command: String, vlc: Bool) -> String? {
        switch command {
        case "play": return "play"
        case "pause": return "pause"
        case "playpause": return vlc ? nil : "playpause"
        case "next track": return vlc ? "next" : "next track"
        case "previous track": return vlc ? "previous" : "previous track"
        default: return nil
        }
    }
}
