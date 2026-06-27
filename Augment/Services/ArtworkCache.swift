import AppKit
import Foundation

final class ArtworkCache {
    typealias ArtworkUpdate = (_ bundleID: String, _ title: String, _ image: NSImage) -> Void

    private var lastSpotifyArtworkURL: String?
    private var cachedSpotifyArtwork: NSImage?
    private var lastLookupTrackTitle: String?
    private var cachedLookupArtwork: NSImage?

    func cachedSpotifyArtwork(for urlString: String, title: String, onUpdate: @escaping ArtworkUpdate) -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        if urlString == lastSpotifyArtworkURL {
            return cachedSpotifyArtwork
        }
        lastSpotifyArtworkURL = urlString
        guard let url = URL(string: urlString) else { return nil }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let img = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                self.cachedSpotifyArtwork = img
                onUpdate("com.spotify.client", title, img)
            }
        }.resume()
        return nil
    }

    func cachedStoreArtwork(bundleID: String, title: String, artist: String, onUpdate: @escaping ArtworkUpdate) -> NSImage? {
        if title == lastLookupTrackTitle {
            return cachedLookupArtwork
        }
        lastLookupTrackTitle = title
        cachedLookupArtwork = nil
        fetchiTunesArtwork(title: title, artist: artist) { [weak self] img in
            guard let self, let img else { return }
            DispatchQueue.main.async {
                self.cachedLookupArtwork = img
                onUpdate(bundleID, title, img)
            }
        }
        return nil
    }

    func appleMusicEmbeddedArtwork() -> NSImage? {
        let source = """
        try
            tell application id "com.apple.Music"
                if player state is stopped then return missing value
                tell current track
                    if (count of artworks) is 0 then return missing value
                    return data of artwork 1
                end tell
            end tell
        on error
            return missing value
        end try
        """
        return MediaScriptRunner.data(source).flatMap { NSImage(data: $0) }
    }

    private func fetchiTunesArtwork(title: String, artist: String, completion: @escaping (NSImage?) -> Void) {
        let query = "\(title) \(artist)"
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encodedQuery)&limit=1&entity=song") else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let urlString = first["artworkUrl100"] as? String else {
                completion(nil)
                return
            }

            let highResUrlString = urlString.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let imgUrl = URL(string: highResUrlString) else {
                completion(nil)
                return
            }

            URLSession.shared.dataTask(with: imgUrl) { imgData, _, _ in
                if let imgData, let img = NSImage(data: imgData) {
                    completion(img)
                } else {
                    completion(nil)
                }
            }.resume()
        }.resume()
    }
}
