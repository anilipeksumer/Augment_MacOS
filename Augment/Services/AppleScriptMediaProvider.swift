import AppKit
import ApplicationServices
import Foundation

final class AppleScriptMediaProvider {
    private let artworkCache: ArtworkCache
    private let onArtworkUpdate: ArtworkCache.ArtworkUpdate

    private let desktopPlayerOrder = [
        "com.spotify.client",
        "com.apple.Music",
        "org.videolan.vlc",
        "com.colliderli.iina",
    ]

    private let spotifyIdleWindowTitles: Set<String> = [
        "Spotify", "Spotify Free", "Spotify Premium", "Spotify Mini Player", "Mini Player",
    ]

    private let musicIdleWindowTitles: Set<String> = [
        "Music", "Apple Music", "Müzik",
    ]

    init(artworkCache: ArtworkCache, onArtworkUpdate: @escaping ArtworkCache.ArtworkUpdate) {
        self.artworkCache = artworkCache
        self.onArtworkUpdate = onArtworkUpdate
    }

    func sources() -> [MediaInfo] {
        var sources: [MediaInfo] = []

        for bid in desktopPlayerOrder {
            guard let info = fetchDesktopPlayer(bundleID: bid, playingOnly: false) else { continue }
            if bid == "com.apple.Music" {
                sources.append(enrichAppleMusicArtwork(info))
            } else {
                sources.append(info)
            }
        }

        sources.append(contentsOf: BrowserMediaProvider.sources(onArtworkUpdate: onArtworkUpdate))

        if !sources.contains(where: { $0.appBundleID == "com.spotify.client" }),
           let spotifyAcc = accessibilitySpotify() {
            sources.append(spotifyAcc)
        }
        if !sources.contains(where: { $0.appBundleID == "com.apple.Music" }),
           let musicAcc = accessibilityMusic() {
            sources.append(musicAcc)
        }

        for bid in BrowserMediaProvider.bundleIDs where !sources.contains(where: { $0.appBundleID == bid }) {
            guard MediaInfoFactory.isAppRunning(bundleID: bid) else { continue }
            for raw in accessibilityWindowTitles(bundleID: bid) {
                if BrowserMediaProvider.mediaTitleNeedles.contains(where: { raw.contains($0) }) {
                    sources.append(MediaInfoFactory.make(bundleID: bid, title: raw, subtitle: "Web", playing: true))
                    break
                }
            }
        }

        return sources
    }

    private func enrichAppleMusicArtwork(_ info: MediaInfo) -> MediaInfo {
        let embeddedArtwork = artworkCache.appleMusicEmbeddedArtwork()
        let fallbackArtwork = embeddedArtwork ?? artworkCache.cachedStoreArtwork(
            bundleID: "com.apple.Music",
            title: info.title,
            artist: info.artist,
            onUpdate: onArtworkUpdate
        )
        return MediaInfoFactory.make(
            bundleID: "com.apple.Music",
            title: info.title,
            subtitle: info.artist,
            playing: info.isPlaying,
            duration: info.duration,
            elapsedTime: info.elapsedTime,
            art: fallbackArtwork
        )
    }

    private func fetchDesktopPlayer(bundleID: String, playingOnly: Bool) -> MediaInfo? {
        guard MediaInfoFactory.isAppRunning(bundleID: bundleID) else { return nil }
        switch bundleID {
        case "com.spotify.client": return spotifyInfo(playingOnly: playingOnly)
        case "com.apple.Music": return musicInfo(playingOnly: playingOnly)
        case "org.videolan.vlc": return vlcInfo()
        case "com.colliderli.iina": return iinaInfo()
        default: return nil
        }
    }

    private func spotifyInfo(playingOnly: Bool) -> MediaInfo? {
        let stateFilter = playingOnly
            ? "if pState is not \"playing\" then return \"\""
            : "if pState is not \"playing\" and pState is not \"paused\" then return \"\""
        let source = """
        try
            tell application id "com.spotify.client"
                set pState to (player state as string)
                \(stateFilter)
                set flag to "1"
                if pState is "paused" then set flag to "0"
                set tn to name of current track
                set ar to ""
                try
                    set ar to artist of current track
                end try
                set dur to (duration of current track) / 1000.0
                set pos to player position
                set artUrl to ""
                try
                    set artUrl to artwork url of current track
                end try
                return tn & "|||" & ar & "|||" & flag & "|||" & dur & "|||" & pos & "|||" & artUrl
            end tell
        on error
            return ""
        end try
        """

        guard let raw = MediaScriptRunner.string(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 3 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }
        let artist = parts[1]
        let playing = parts[2] == "1"
        let duration = parts.count > 3 ? MediaInfoFactory.parseDouble(parts[3]) : nil
        let elapsedTime = parts.count > 4 ? MediaInfoFactory.parseDouble(parts[4]) : nil
        let artUrl = parts.count > 5 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let art = artworkCache.cachedSpotifyArtwork(for: artUrl, title: title, onUpdate: onArtworkUpdate)
            ?? artworkCache.cachedStoreArtwork(bundleID: "com.spotify.client", title: title, artist: artist, onUpdate: onArtworkUpdate)

        return MediaInfoFactory.make(
            bundleID: "com.spotify.client",
            title: title,
            subtitle: artist,
            playing: playing,
            duration: duration,
            elapsedTime: elapsedTime,
            art: art
        )
    }

    private func musicInfo(playingOnly: Bool) -> MediaInfo? {
        let stateFilter = playingOnly
            ? "if pState is not \"playing\" then return \"\""
            : "if pState is not \"playing\" and pState is not \"paused\" then return \"\""
        let source = """
        try
            tell application id "com.apple.Music"
                set pState to (player state as string)
                \(stateFilter)
                set flag to "1"
                if pState is "paused" then set flag to "0"
                set tn to name of current track
                set ar to ""
                try
                    set ar to artist of current track
                end try
                set dur to duration of current track
                set pos to player position
                return tn & "|||" & ar & "|||" & flag & "|||" & dur & "|||" & pos
            end tell
        on error
            return ""
        end try
        """

        guard let raw = MediaScriptRunner.string(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 3 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }
        return MediaInfoFactory.make(
            bundleID: "com.apple.Music",
            title: title,
            subtitle: parts[1],
            playing: parts[2] == "1",
            duration: parts.count > 3 ? MediaInfoFactory.parseDouble(parts[3]) : nil,
            elapsedTime: parts.count > 4 ? MediaInfoFactory.parseDouble(parts[4]) : nil
        )
    }

    private func vlcInfo() -> MediaInfo? {
        let source = """
        try
            tell application id "org.videolan.vlc"
                set n to name of current item
                if n is missing value or n is "" then return ""
                set playState to "0"
                if playing then set playState to "1"
                set dur to duration of current item
                set pos to current time
                return n & "|||VLC|||" & playState & "|||" & dur & "|||" & pos
            end tell
        on error
            return ""
        end try
        """
        guard let raw = MediaScriptRunner.string(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 2 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }
        return MediaInfoFactory.make(
            bundleID: "org.videolan.vlc",
            title: title,
            subtitle: parts[1].isEmpty ? " " : parts[1],
            playing: parts.count > 2 ? (parts[2] == "1") : true,
            duration: parts.count > 3 ? MediaInfoFactory.parseDouble(parts[3]) : nil,
            elapsedTime: parts.count > 4 ? MediaInfoFactory.parseDouble(parts[4]) : nil
        )
    }

    private func iinaInfo() -> MediaInfo? {
        let source = """
        try
            tell application id "com.colliderli.iina"
                if (count of windows) is 0 then return ""
                set w to name of front window
                if w is "" or w is missing value then return ""
                return w & "|||IINA|||1"
            end tell
        on error
            return ""
        end try
        """
        guard let raw = MediaScriptRunner.string(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 2 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }
        return MediaInfoFactory.make(
            bundleID: "com.colliderli.iina",
            title: title,
            subtitle: parts[1].isEmpty ? " " : parts[1],
            playing: parts.count > 2 ? (parts[2] == "1") : true
        )
    }

    private func accessibilitySpotify() -> MediaInfo? {
        let bid = "com.spotify.client"
        guard MediaInfoFactory.isAppRunning(bundleID: bid) else { return nil }
        for raw in accessibilityWindowTitles(bundleID: bid) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if spotifyIdleWindowTitles.contains(t) { continue }
            if let pair = splitTrackAndArtist(from: raw) {
                let sub = pair.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : pair.1
                return MediaInfoFactory.make(bundleID: bid, title: pair.0, subtitle: sub, playing: true)
            }
        }
        return nil
    }

    private func accessibilityMusic() -> MediaInfo? {
        let bid = "com.apple.Music"
        guard MediaInfoFactory.isAppRunning(bundleID: bid) else { return nil }
        for raw in accessibilityWindowTitles(bundleID: bid) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if musicIdleWindowTitles.contains(t) { continue }
            if let pair = splitTrackAndArtist(from: raw) {
                let sub = pair.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " " : pair.1
                return MediaInfoFactory.make(bundleID: bid, title: pair.0, subtitle: sub, playing: true)
            }
        }
        return nil
    }

    private func accessibilityWindowTitles(bundleID: String) -> [String] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return []
        }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var windowsObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsObj) == .success,
              let nsArray = windowsObj as? NSArray else {
            return []
        }
        var titles: [String] = []
        for i in 0..<nsArray.count {
            let winAny = nsArray[i]
            guard let win = AXElementCoercion.element(winAny as AnyObject) else { continue }
            var titleObj: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleObj) == .success,
                  let t = titleObj as? String, !t.isEmpty else { continue }
            titles.append(t)
        }
        return titles
    }

    private func splitTrackAndArtist(from raw: String) -> (String, String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let seps = [" – ", " — ", " - ", " • ", " · "]
        for sep in seps {
            let parts = trimmed.components(separatedBy: sep)
            if parts.count >= 2 {
                let left = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = parts[1...].joined(separator: sep).trimmingCharacters(in: .whitespacesAndNewlines)
                if left.count >= 1, right.count >= 1 { return (left, right) }
            }
        }
        if trimmed.count >= 2 { return (trimmed, " ") }
        return nil
    }
}
