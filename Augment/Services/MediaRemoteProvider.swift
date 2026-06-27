import Foundation

enum MediaRemoteProvider {
    private typealias MRGetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private typealias MRGetNowPlayingClient = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private typealias MRGetNowPlayingApplicationIsPlaying = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    typealias SendCommand = @convention(c) (Int32, NSDictionary?) -> Bool
    private typealias MRNowPlayingClientGetBundleIdentifier = @convention(c) (AnyObject?) -> NSString?

    static var readsUnavailable: Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion > 15 { return true }
        if version.majorVersion == 15 && version.minorVersion >= 4 { return true }
        return false
    }

    private static let mediaRemoteBundle: CFBundle? = {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework" as CFString
        guard let url = CFURLCreateWithFileSystemPath(nil, path, .cfurlposixPathStyle, false) else { return nil }
        return CFBundleCreate(nil, url)
    }()

    private static let getNowPlayingInfo: MRGetNowPlayingInfo? = castFn("MRMediaRemoteGetNowPlayingInfo")
    private static let getNowPlayingClient: MRGetNowPlayingClient? = castFn("MRMediaRemoteGetNowPlayingClient")
    private static let getNowPlayingApplicationIsPlaying: MRGetNowPlayingApplicationIsPlaying? = castFn("MRMediaRemoteGetNowPlayingApplicationIsPlaying")
    static let sendMediaCommand: SendCommand? = castFn("MRMediaRemoteSendCommand")
    private static let bundleIdentifierFromClient: MRNowPlayingClientGetBundleIdentifier? = castFn("MRNowPlayingClientGetBundleIdentifier")
    private static let parentBundleIdentifierFromClient: MRNowPlayingClientGetBundleIdentifier? = castFn("MRNowPlayingClientGetParentAppBundleIdentifier")

    private static func castFn<T>(_ name: String) -> T? {
        guard let bundle = mediaRemoteBundle,
              let ptr = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    static func fetch(
        queue: DispatchQueue,
        completion: @escaping (_ bundleID: String?, _ info: [String: Any]?, _ isPlaying: Bool?, _ gotPlaying: Bool) -> Void
    ) {
        guard !readsUnavailable else {
            completion(nil, nil, nil, false)
            return
        }

        var resolvedBundleID: String?
        var infoDict: [String: Any]?
        var systemPlaying = false
        var gotPlayingCallback = false
        let group = DispatchGroup()

        if let getNowPlayingClient {
            group.enter()
            getNowPlayingClient(queue) { client in
                defer { group.leave() }
                resolvedBundleID = bundleID(from: client)
            }
        }

        if let getNowPlayingInfo {
            group.enter()
            getNowPlayingInfo(queue) { cf in
                defer { group.leave() }
                if let cf {
                    infoDict = cf as? [String: Any] ?? (cf as NSDictionary as? [String: Any])
                }
            }
        }

        if let getNowPlayingApplicationIsPlaying {
            group.enter()
            getNowPlayingApplicationIsPlaying(queue) { playing in
                defer { group.leave() }
                systemPlaying = playing
                gotPlayingCallback = true
            }
        }

        group.notify(queue: queue) {
            completion(resolvedBundleID, infoDict, systemPlaying, gotPlayingCallback)
        }
    }

    private static func bundleID(from client: AnyObject?) -> String? {
        guard let client else { return nil }
        if let fn = bundleIdentifierFromClient {
            let value = fn(client) as String?
            if let value, !value.isEmpty { return value }
        }
        if let fn = parentBundleIdentifierFromClient {
            let value = fn(client) as String?
            if let value, !value.isEmpty { return value }
        }
        return nil
    }
}
