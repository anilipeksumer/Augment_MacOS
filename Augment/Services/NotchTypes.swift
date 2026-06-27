import AppKit
import Foundation

struct BatteryInfo {
    let level: Int
    let isCharging: Bool
    let isPluggedIn: Bool
}

struct ShelfItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var icon: NSImage? { NSWorkspace.shared.icon(forFile: url.path) }
}

struct MediaInfo {
    let title: String
    let artist: String
    let appName: String
    let appIcon: NSImage?
    let albumArt: NSImage?
    let isPlaying: Bool
    let duration: Double?
    let elapsedTime: Double?
    /// Used for AppleScript / MR routing; avoids localized app names like "Müzik".
    let appBundleID: String?
    let isJSDisabled: Bool
}
