import AppKit
import Foundation

enum BrowserMediaProvider {
    private static let artworkLock = NSLock()
    private static var artworkByURL: [String: NSImage] = [:]
    private static var artworkRequests = Set<String>()
    static let browserIDs: [(String, String)] = [
        ("com.apple.Safari", "safari"),
        ("com.google.Chrome", "chrome"),
        ("company.thebrowser.Browser", "arc"),
        ("com.microsoft.edgemac", "edge"),
        ("com.brave.Browser", "brave"),
    ]

    static var bundleIDs: [String] {
        browserIDs.map(\.0)
    }

    static let mediaTitleNeedles = [
        "YouTube", "Netflix", "Twitch", "Disney", "Prime Video", "Spotify", "Apple Music", "YouTube Music",
    ]

    static func isBrowser(bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    static func sources(onArtworkUpdate: @escaping ArtworkCache.ArtworkUpdate) -> [MediaInfo] {
        browserIDs.compactMap { bid, kind in
            script(bundleID: bid, kind: kind, onArtworkUpdate: onArtworkUpdate)
        }
    }

    static func control(command: String, bundleID: String) {
        let jsCmd: String
        switch command {
        case "play":
            jsCmd = "var v = document.querySelector('video, audio'); if (v) { v.play(); }"
        case "pause":
            jsCmd = "var v = document.querySelector('video, audio'); if (v) { v.pause(); }"
        case "playpause":
            jsCmd = "var v = document.querySelector('video, audio'); if (v) { if (v.paused) { v.play(); } else { v.pause(); } }"
        case "seek_backward":
            jsCmd = "var v = document.querySelector('video, audio'); if (v) { v.currentTime = Math.max(0, v.currentTime - 10); }"
        case "seek_forward":
            jsCmd = "var v = document.querySelector('video, audio'); if (v) { v.currentTime = Math.min(v.duration, v.currentTime + 10); }"
        default:
            return
        }
        executeJavaScript(jsCmd, bundleID: bundleID)
    }

    static func seek(to time: Double, bundleID: String) {
        executeJavaScript("var v = document.querySelector('video, audio'); if (v) { v.currentTime = \(time); }", bundleID: bundleID)
    }

    private static func script(
        bundleID: String,
        kind: String,
        onArtworkUpdate: @escaping ArtworkCache.ArtworkUpdate
    ) -> MediaInfo? {
        guard MediaInfoFactory.isAppRunning(bundleID: bundleID) else { return nil }

        let source: String
        if kind == "safari" {
            source = """
            try
                tell application id "com.apple.Safari"
                    set tabTitle to name of front document
                    set tabURL to URL of front document
                    if tabTitle contains "YouTube" or tabTitle contains "Netflix" or tabTitle contains "Twitch" or tabTitle contains "Disney" or tabTitle contains "Prime Video" or tabTitle contains "Spotify" or tabTitle contains "Apple Music" or tabTitle contains "YouTube Music" then
                        try
                            set jsRes to do JavaScript "(function() { var v = document.querySelector('video') || document.querySelector('audio'); if (v) { return (v.paused ? '0' : '1') + '|' + (v.duration || 0) + '|' + (v.currentTime || 0); } return '1|0|0'; })()" in front document
                        on error
                            set jsRes to "JS_ERR"
                        end try
                        return tabTitle & "|||Web|||" & jsRes & "|||" & tabURL
                    end if
                end tell
            on error
                return ""
            end try
            """
        } else {
            source = """
            try
                tell application id "\(bundleID)"
                    set tabTitle to title of active tab of front window
                    set tabURL to URL of active tab of front window
                    if tabTitle contains "YouTube" or tabTitle contains "Netflix" or tabTitle contains "Twitch" or tabTitle contains "Disney" or tabTitle contains "Prime Video" or tabTitle contains "Spotify" or tabTitle contains "Apple Music" or tabTitle contains "YouTube Music" then
                        try
                            tell active tab of front window to set jsRes to execute javascript "(function() { var v = document.querySelector('video') || document.querySelector('audio'); if (v) { return (v.paused ? '0' : '1') + '|' + (v.duration || 0) + '|' + (v.currentTime || 0); } return '1|0|0'; })()"
                        on error
                            set jsRes to "JS_ERR"
                        end try
                        return tabTitle & "|||Web|||" & jsRes & "|||" & tabURL
                    end if
                end tell
            on error
                return ""
            end try
            """
        }

        guard let raw = MediaScriptRunner.string(source), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 3 else { return nil }
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return nil }
        let pageURL = parts.count > 3
            ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let art = browserArtwork(
            pageURL: pageURL,
            bundleID: bundleID,
            title: title,
            onUpdate: onArtworkUpdate
        )

        let jsData = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        if jsData == "JS_ERR" {
            return MediaInfoFactory.make(
                bundleID: bundleID,
                title: title,
                subtitle: mediaServiceName(for: title),
                playing: true,
                art: art,
                isJSDisabled: true
            )
        }

        let jsParts = jsData.components(separatedBy: "|")
        let duration = jsParts.count > 1 ? MediaInfoFactory.parseDouble(jsParts[1]) : nil
        let elapsedTime = jsParts.count > 2 ? MediaInfoFactory.parseDouble(jsParts[2]) : nil
        return MediaInfoFactory.make(
            bundleID: bundleID,
            title: title,
            subtitle: parts[1].isEmpty ? " " : parts[1],
            playing: jsParts.first == "1",
            duration: (duration ?? 0) > 0 ? duration : nil,
            elapsedTime: (elapsedTime ?? 0) > 0 ? elapsedTime : nil,
            art: art
        )
    }

    private static func browserArtwork(
        pageURL: String,
        bundleID: String,
        title: String,
        onUpdate: @escaping ArtworkCache.ArtworkUpdate
    ) -> NSImage? {
        guard let thumbnailURL = youtubeThumbnailURL(from: pageURL) else { return nil }
        let key = thumbnailURL.absoluteString
        artworkLock.lock()
        if let cached = artworkByURL[key] {
            artworkLock.unlock()
            return cached
        }
        let shouldFetch = artworkRequests.insert(key).inserted
        artworkLock.unlock()
        guard shouldFetch else { return nil }

        var request = URLRequest(url: thumbnailURL)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data,
                  let image = NSImage(data: data) else {
                artworkLock.lock()
                artworkRequests.remove(key)
                artworkLock.unlock()
                return
            }
            artworkLock.lock()
            artworkByURL[key] = image
            artworkRequests.remove(key)
            if artworkByURL.count > 24, let oldest = artworkByURL.keys.first {
                artworkByURL.removeValue(forKey: oldest)
            }
            artworkLock.unlock()
            DispatchQueue.main.async {
                onUpdate(bundleID, title, image)
            }
        }.resume()
        return nil
    }

    private static func youtubeThumbnailURL(from pageURL: String) -> URL? {
        guard let url = URL(string: pageURL),
              let host = url.host?.lowercased() else { return nil }
        let videoID: String?
        if host == "youtu.be" {
            videoID = url.pathComponents.dropFirst().first
        } else if host.hasSuffix("youtube.com") {
            if url.path == "/watch" {
                videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if url.pathComponents.count > 2,
                      ["shorts", "embed"].contains(url.pathComponents[1]) {
                videoID = url.pathComponents[2]
            } else {
                videoID = nil
            }
        } else {
            videoID = nil
        }
        guard let videoID, !videoID.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    private static func mediaServiceName(for title: String) -> String {
        mediaTitleNeedles.first(where: {
            title.localizedCaseInsensitiveContains($0)
        }) ?? "Web Media"
    }

    private static func executeJavaScript(_ jsCmd: String, bundleID: String) {
        let source: String
        if bundleID == "com.apple.Safari" {
            source = """
            try
                tell application id "com.apple.Safari"
                    do JavaScript "\(jsCmd)" in front document
                end tell
            end try
            """
        } else {
            source = """
            try
                tell application id "\(bundleID)"
                    tell active tab of front window to execute javascript "\(jsCmd)"
                end tell
            end try
            """
        }
        _ = MediaScriptRunner.string(source)
    }
}
