import AppKit
import Combine
import Foundation

final class MediaManager: NSObject, ObservableObject {
    static let shared = MediaManager()
    
    @Published private(set) var currentMedia: MediaInfo?
    @Published var availableSources: [MediaInfo] = []
    @Published private(set) var isCommandInFlight = false
    @Published var activeSourceIndex: Int = 0 {
        didSet {
            updateCurrentMedia()
        }
    }
    
    private var preferredBundleID: String?
    private var userPinnedSource = false
    private var lastPlayingBundleID: String?
    /// Consecutive fetches in which the user's pinned source failed to show
    /// up. A single transient miss (e.g. a slow browser AppleScript/JS call)
    /// used to drop the pin immediately, snapping the notch back to whatever
    /// source was playing — so a play/pause tap right after switching sources
    /// silently landed on the wrong app. Requiring a few consecutive misses
    /// gives flaky per-source fetches room to recover before we give up on
    /// the user's choice.
    private var preferredSourceMissStreak = 0
    private let preferredSourceMissLimit = 3
    
    private var timer: Timer?
    private var debounceItem: DispatchWorkItem?
    private var delayedFetchItem: DispatchWorkItem?
    private var lastFingerprint: String?
    private var fetchGeneration: UInt64 = 0
    private var fetchInFlight = false
    private var needsFetchAfterCurrent = false

    private let artworkCache = ArtworkCache()
    private lazy var appleScriptProvider = AppleScriptMediaProvider(
        artworkCache: artworkCache,
        onArtworkUpdate: { [weak self] bundleID, title, image in
            self?.applyArtworkUpdate(bundleID: bundleID, title: title, image: image)
        }
    )
    
    private let mrKeyTitle = "kMRMediaRemoteNowPlayingInfoTitle"
    private let mrKeyArtist = "kMRMediaRemoteNowPlayingInfoArtist"
    private let mrKeyAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
    private let mrKeyRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    private let mrKeyArtwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private let mrKeyBundleID = "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier"
    private let mrKeyDuration = "kMRMediaRemoteNowPlayingInfoDuration"
    private let mrKeyElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
    
    // MARK: - Lifecycle
    
    func start() {
        // Observe standard system notifications for media changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scheduleFetch),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(scheduleFetch),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(scheduleFetch),
            name: NSNotification.Name("kMRMediaRemotePlaybackStateDidChangeNotification"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(scheduleFetch),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            object: nil
        )
        
        // Timer as a fallback and to update the progress bar elapsed time regularly
        timer?.invalidate()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        fire()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        debounceItem?.cancel()
        debounceItem = nil
        delayedFetchItem?.cancel()
        delayedFetchItem = nil
        fetchGeneration &+= 1
        fetchInFlight = false
        needsFetchAfterCurrent = false
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    @objc private func scheduleFetch() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.performFetch() }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }
    
    func fire() {
        performFetch()
    }
    
    // MARK: - Fetching Logic
    
    private func performFetch() {
        if isCommandInFlight {
            needsFetchAfterCurrent = true
            return
        }
        if fetchInFlight {
            needsFetchAfterCurrent = true
            return
        }
        fetchInFlight = true
        fetchGeneration &+= 1
        let generation = fetchGeneration
        let previousSources = availableSources
        let queue = DispatchQueue.global(qos: .utility)
        
        MediaRemoteProvider.fetch(queue: queue) { [weak self] resolvedBundleID, infoDict, systemPlaying, gotPlayingCallback in
            guard let self else { return }
            
            var mrSource: MediaInfo? = nil
            if !MediaRemoteProvider.readsUnavailable, let dict = infoDict {
                let title = self.anyString(from: dict, keys: [self.mrKeyTitle, "title", "Title"])
                let artist = self.anyString(from: dict, keys: [self.mrKeyArtist, "artist", "Artist"])
                let album = self.anyString(from: dict, keys: [self.mrKeyAlbum, "album", "Album"])
                let rate = self.double(from: dict, key: self.mrKeyRate) ?? 0
                let idFromDict = dict[self.mrKeyBundleID] as? String
                let resolvedID = resolvedBundleID ?? idFromDict
                
                let artworkData = self.data(from: dict, key: self.mrKeyArtwork)
                let artImage = artworkData.flatMap { NSImage(data: $0) }
                
                let duration = self.double(from: dict, key: self.mrKeyDuration)
                let elapsedTime = self.double(from: dict, key: self.mrKeyElapsedTime)
                
                let playing: Bool = gotPlayingCallback ? (systemPlaying ?? false) : (rate > 0)
                
                let appTitle = resolvedID.flatMap { MediaInfoFactory.displayName(forBundleID: $0) }
                    ?? resolvedID.map { $0.components(separatedBy: ".").last?.capitalized ?? $0 }
                let appIcon = resolvedID.flatMap { MediaInfoFactory.icon(forBundleID: $0) }
                
                if let title, !title.isEmpty {
                    let subtitle = artist ?? album ?? appTitle ?? "Now Playing"
                    mrSource = MediaInfo(
                        title: title,
                        artist: subtitle,
                        appName: appTitle ?? "Media",
                        appIcon: appIcon,
                        albumArt: artImage,
                        isPlaying: playing,
                        duration: duration,
                        elapsedTime: elapsedTime,
                        appBundleID: resolvedID,
                        isJSDisabled: false
                    )
                }
            }
            
            // Gather all running/active media sources
            var allSources = self.appleScriptProvider.sources()
            
            // Merge MediaRemote source if available and not already represented
            var mediaRemoteSourceKeys = Set<String>()
            if let mr = mrSource {
                if let idx = allSources.firstIndex(where: { $0.appBundleID == mr.appBundleID }) {
                    let existing = allSources[idx]
                    // For browser tabs, MediaRemote's playback-rate flag lags the
                    // page's real <video>/<audio> state (that's what made the
                    // YouTube play/pause button look inverted: the icon reflected
                    // MediaRemote while the actual toggle acted on live DOM state).
                    // The AppleScript/JS scrape in BrowserMediaProvider reads that
                    // state directly, so trust it over MediaRemote for browsers.
                    let isBrowserSource = mr.appBundleID.map(BrowserMediaProvider.isBrowser) ?? false
                    let merged = MediaInfo(
                        title: mr.title,
                        artist: mr.artist,
                        appName: mr.appName,
                        appIcon: mr.appIcon ?? existing.appIcon,
                        albumArt: mr.albumArt ?? existing.albumArt,
                        isPlaying: isBrowserSource ? existing.isPlaying : mr.isPlaying,
                        duration: (isBrowserSource ? existing.duration : mr.duration) ?? existing.duration,
                        elapsedTime: (isBrowserSource ? existing.elapsedTime : mr.elapsedTime) ?? existing.elapsedTime,
                        appBundleID: mr.appBundleID,
                        isJSDisabled: existing.isJSDisabled
                    )
                    allSources[idx] = merged
                    mediaRemoteSourceKeys.insert(self.sourceKey(for: merged))
                } else {
                    allSources.insert(mr, at: 0)
                    mediaRemoteSourceKeys.insert(self.sourceKey(for: mr))
                }
            }

            // Browser scripting may expose metadata while Chrome/Safari's
            // JavaScript-from-Apple-Events switch is disabled. In that case
            // playback state is unknown, not "always playing". Preserve the
            // last (including optimistic button) state until MediaRemote
            // supplies an authoritative value.
            allSources = allSources.map { source in
                let key = self.sourceKey(for: source)
                guard source.isJSDisabled,
                      !mediaRemoteSourceKeys.contains(key),
                      let previous = previousSources.first(where: {
                          self.sourceKey(for: $0) == key
                      }) else { return source }
                return MediaInfo(
                    title: source.title,
                    artist: source.artist,
                    appName: source.appName,
                    appIcon: source.appIcon,
                    albumArt: source.albumArt,
                    isPlaying: previous.isPlaying,
                    duration: source.duration,
                    elapsedTime: source.elapsedTime,
                    appBundleID: source.appBundleID,
                    isJSDisabled: source.isJSDisabled
                )
            }
            
            // Check fingerprint to avoid unnecessary updates
            let fp = allSources.map { info in
                let bid = info.appBundleID ?? ""
                let isPlaying = info.isPlaying
                let elapsed = info.elapsedTime ?? 0.0
                let dur = info.duration ?? 0.0
                let title = info.title
                let artist = info.artist
                let artIdentity = info.albumArt.map { ObjectIdentifier($0).hashValue } ?? 0
                return "\(bid)|\(title)|\(artist)|\(isPlaying)|\(artIdentity)|\(Int(elapsed))|\(Int(dur))"
            }.joined(separator: "||")
            
            DispatchQueue.main.async {
                guard generation == self.fetchGeneration else { return }
                self.fetchInFlight = false
                let runDeferredFetch = self.needsFetchAfterCurrent
                self.needsFetchAfterCurrent = false

                // A fetch that started before a skip/seek command may contain
                // the old track and progress. Do not let that stale snapshot
                // redraw the bar while the command is still settling.
                if self.isCommandInFlight {
                    self.needsFetchAfterCurrent = true
                    return
                }

                if fp == self.lastFingerprint {
                    if runDeferredFetch {
                        self.scheduleFetch()
                    }
                    return
                }
                self.lastFingerprint = fp
                self.updateSourcesList(allSources)
                if runDeferredFetch {
                    self.scheduleFetch()
                }
            }
        }
    }
    
    private func updateSourcesList(_ newSources: [MediaInfo]) {
        self.availableSources = newSources
        
        if newSources.isEmpty {
            self.activeSourceIndex = 0
            self.preferredBundleID = nil
            self.userPinnedSource = false
            self.currentMedia = nil
            self.lastPlayingBundleID = nil
            return
        }
        
        let playingSources = newSources.filter { $0.isPlaying }
        
        if let preferred = preferredBundleID {
            if newSources.contains(where: { $0.appBundleID == preferred }) {
                preferredSourceMissStreak = 0
            } else {
                preferredSourceMissStreak += 1
                if preferredSourceMissStreak >= preferredSourceMissLimit {
                    preferredBundleID = nil
                    userPinnedSource = false
                    preferredSourceMissStreak = 0
                }
            }
        }

        // Auto-switch to newly playing source only until the user explicitly picks one.
        if !userPinnedSource,
           let newlyPlaying = playingSources.first(where: { $0.appBundleID != lastPlayingBundleID }) {
            preferredBundleID = newlyPlaying.appBundleID
        }
        lastPlayingBundleID = playingSources.first?.appBundleID
        
        if let preferred = preferredBundleID,
           let idx = newSources.firstIndex(where: { $0.appBundleID == preferred }) {
            self.activeSourceIndex = idx
        } else {
            if let idx = newSources.firstIndex(where: { $0.isPlaying }) {
                self.activeSourceIndex = idx
            } else {
                self.activeSourceIndex = 0
            }
        }
        
        updateCurrentMedia()
    }

    private func sourceKey(for source: MediaInfo) -> String {
        "\(source.appBundleID ?? source.appName)|\(source.title)"
    }
    
    private func updateCurrentMedia() {
        if availableSources.isEmpty {
            currentMedia = nil
        } else if activeSourceIndex >= 0 && activeSourceIndex < availableSources.count {
            currentMedia = availableSources[activeSourceIndex]
        } else {
            currentMedia = availableSources.first
        }
    }
    
    func cycleSource(forward: Bool) {
        guard !availableSources.isEmpty else { return }
        var nextIdx = activeSourceIndex
        if forward {
            nextIdx = (nextIdx + 1) % availableSources.count
        } else {
            nextIdx = (nextIdx - 1 + availableSources.count) % availableSources.count
        }
        preferredBundleID = availableSources[nextIdx].appBundleID
        userPinnedSource = true
        activeSourceIndex = nextIdx
    }

    func selectSource(at index: Int) {
        guard availableSources.indices.contains(index) else { return }
        preferredBundleID = availableSources[index].appBundleID
        userPinnedSource = true
        activeSourceIndex = index
    }
    
    
    // MARK: - Dictionary Helpers
    
    private func anyString(from dict: [String: Any]?, keys: [String]) -> String? {
        guard let dict else { return nil }
        for k in keys {
            guard let v = dict[k] else { continue }
            if let s = v as? String, !s.isEmpty { return s }
            if let s = v as? NSString, s.length > 0 { return s as String }
            if let n = v as? NSNumber { let t = n.stringValue; if !t.isEmpty { return t } }
        }
        return nil
    }
    
    private func double(from dict: [String: Any]?, key: String) -> Double? {
        guard let dict else { return nil }
        if let d = dict[key] as? Double { return d }
        if let n = dict[key] as? NSNumber { return n.doubleValue }
        return nil
    }
    
    private func data(from dict: [String: Any]?, key: String) -> Data? {
        guard let dict else { return nil }
        if let d = dict[key] as? Data { return d }
        if let n = dict[key] as? NSData { return Data(referencing: n) }
        return nil
    }
    
    // MARK: - Artwork Updates

    private func applyArtworkUpdate(bundleID: String, title: String, image: NSImage) {
        guard let idx = availableSources.firstIndex(where: { $0.appBundleID == bundleID && $0.title == title }) else {
            return
        }
        let current = availableSources[idx]
        let updated = MediaInfo(
            title: current.title,
            artist: current.artist,
            appName: current.appName,
            appIcon: current.appIcon,
            albumArt: image,
            isPlaying: current.isPlaying,
            duration: current.duration,
            elapsedTime: current.elapsedTime,
            appBundleID: current.appBundleID,
            isJSDisabled: current.isJSDisabled
        )
        availableSources[idx] = updated
        if activeSourceIndex == idx {
            currentMedia = updated
        }
    }

    // MARK: - Playback Commands

    func sendCommand(_ command: String, bundleID: String?, fallbackAppName: String?) {
        guard !isCommandInFlight else { return }
        isCommandInFlight = true
        debounceItem?.cancel()
        delayedFetchItem?.cancel()
        MediaCommandSender.sendCommand(
            command,
            bundleID: bundleID,
            fallbackAppName: fallbackAppName,
            currentMedia: currentMedia
        ) { [weak self] in
            self?.finishMediaCommand()
        }
        applyOptimisticPlaybackState(for: command, bundleID: bundleID)
    }

    static func sendCommand(_ command: String, bundleID: String?, fallbackAppName: String?) {
        MediaManager.shared.sendCommand(command, bundleID: bundleID, fallbackAppName: fallbackAppName)
    }

    static func seekToTime(_ time: Double, bundleID: String?, fallbackAppName: String?) {
        MediaManager.shared.seekToTime(time, bundleID: bundleID, fallbackAppName: fallbackAppName)
    }

    private func seekToTime(_ time: Double, bundleID: String?, fallbackAppName: String?) {
        guard !isCommandInFlight else { return }
        isCommandInFlight = true
        debounceItem?.cancel()
        delayedFetchItem?.cancel()
        MediaCommandSender.seekToTime(
            time,
            bundleID: bundleID,
            fallbackAppName: fallbackAppName
        ) { [weak self] in
            self?.finishMediaCommand()
        }
    }

    private func finishMediaCommand() {
        isCommandInFlight = false
        needsFetchAfterCurrent = false
        scheduleFetch()
        scheduleDelayedFetch(after: 0.8)
    }

    private func scheduleDelayedFetch(after delay: TimeInterval) {
        delayedFetchItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.scheduleFetch() }
        delayedFetchItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func applyOptimisticPlaybackState(for command: String, bundleID: String?) {
        let lowered = command.lowercased()
        let newState: Bool?
        switch lowered {
        case "play":
            newState = true
        case "pause":
            newState = false
        case "playpause":
            newState = !(currentMedia?.isPlaying ?? false)
        default:
            newState = nil
        }
        guard let newState else { return }

        let targetIndex: Int?
        if let bundleID {
            targetIndex = availableSources.firstIndex { $0.appBundleID == bundleID }
        } else {
            targetIndex = availableSources.indices.contains(activeSourceIndex) ? activeSourceIndex : nil
        }
        guard let idx = targetIndex else { return }
        let old = availableSources[idx]
        let updated = MediaInfo(
            title: old.title,
            artist: old.artist,
            appName: old.appName,
            appIcon: old.appIcon,
            albumArt: old.albumArt,
            isPlaying: newState,
            duration: old.duration,
            elapsedTime: old.elapsedTime,
            appBundleID: old.appBundleID,
            isJSDisabled: old.isJSDisabled
        )
        availableSources[idx] = updated
        if idx == activeSourceIndex {
            currentMedia = updated
        }
    }
}
