import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

/// Returns the window server ID behind an Accessibility window. Private but
/// long-stable (exported by HIServices since 10.x) and the standard way
/// AltTab, Rectangle and DockDoor map AX windows to real window IDs —
/// the public `AXWindowNumber` attribute is unsupported by most apps.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowServerID(of element: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
}

/// Snapshot describing a single on-screen window owned by another process.
struct DiscoveredWindow: Identifiable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let title: String?
    let frame: CGRect
    let layer: Int
    var isMinimized: Bool = false
}

/// A `DiscoveredWindow` paired with an optional captured thumbnail. Used by
/// the Dock preview panel to render live previews next to the cursor.
struct WindowSnapshot: Identifiable, Hashable {
    let window: DiscoveredWindow
    let thumbnail: CGImage?

    init(window: DiscoveredWindow, thumbnail: CGImage?) {
        self.window = window
        self.thumbnail = thumbnail
    }
    var id: CGWindowID { window.id }

    static func == (lhs: WindowSnapshot, rhs: WindowSnapshot) -> Bool {
        lhs.window == rhs.window
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(window)
    }
}

/// Enumerates windows of other processes and captures lightweight thumbnails
/// for the Dock preview panel.
///
/// Window enumeration uses `CGWindowListCopyWindowInfo` with
/// `optionOnScreenOnly | excludeDesktopElements`. Per-window thumbnails are
/// produced by `CGWindowListCreateImage` and downscaled to a small target
/// size, with a short-lived in-memory cache so that repeated hovers over the
/// same Dock icon don't re-issue identical capture requests to the
/// WindowServer.
final class WindowDiscoveryService {

    private struct CachedThumbnail {
        let image: CGImage
        let timestamp: CFTimeInterval
    }

    /// Cache TTL chosen to feel responsive while still allowing the first
    /// frame to be reused if the user briefly moves off and back onto the
    /// same icon.
    private let cacheTTL: CFTimeInterval = 1.5
    private let cacheLock = NSLock()
    private var thumbnailCache: [CGWindowID: CachedThumbnail] = [:]

    /// Long-lived cache for "last known good" snapshots. When a window is 
    /// minimized, macOS stops providing its content, so we fall back to the 
    /// last frame we captured while it was on-screen.
    private var persistentThumbnailCache: [CGWindowID: CGImage] = [:]
    private var knownWindows: [CGWindowID: DiscoveredWindow] = [:]

    // MARK: - Window enumeration

    /// Returns every on-screen window from other applications, optionally
    /// filtered to a single bundle id. Uses `CGWindowListCopyWindowInfo`
    /// with `optionOnScreenOnly | excludeDesktopElements`.
    func windows(forBundleIdentifier bundleID: String? = nil) -> [DiscoveredWindow] {
        windowsFromCG(
            options: [.optionOnScreenOnly, .excludeDesktopElements],
            bundleID: bundleID,
            minimumShortSide: 100
        )
    }

    private func windowsFromCG(
        options: CGWindowListOption,
        bundleID: String?,
        minimumShortSide: CGFloat
    ) -> [DiscoveredWindow] {
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let runningApps = NSWorkspace.shared.runningApplications
        let filterPID: pid_t? = bundleID.flatMap { id in
            runningApps.first(where: { $0.bundleIdentifier == id })?.processIdentifier
        }

        // Fetch standard AX windows of the app for filtering helper windows/previews
        var standardFrames: [CGRect] = []
        var standardTitles: [String] = []
        var standardIDs = Set<CGWindowID>()
        if let pid = filterPID {
            let appElement = AXUIElementCreateApplication(pid)
            let axWins = standardAXWindows(of: appElement)
            for ax in axWins {
                if let id = windowServerID(of: ax) { standardIDs.insert(id) }
                if let frame = axFrame(for: ax) {
                    standardFrames.append(frame)
                }
                var titleValue: AnyObject?
                if AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let title = titleValue as? String {
                    standardTitles.append(title)
                }
            }
        }

        let mapped: [DiscoveredWindow] = info.compactMap { entry in
            guard
                let id = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let owner = entry[kCGWindowOwnerName as String] as? String,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            if let filterPID, pid != filterPID { return nil }

            // Layer 0 is standard, but minimized/offscreen windows can sometimes be bumped.
            // Allow low layers or anything with a title.
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            let title = entry[kCGWindowName as String] as? String
            guard layer < 100 || (title != nil && !title!.isEmpty) else { return nil }

            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            // Filter tiny Window Server surfaces (menu shadows, indicators). Threshold is lower
            // for off-screen/minimized passes so dock tiles still match.
            guard frame.width >= minimumShortSide, frame.height >= minimumShortSide else { return nil }

            // Apply standard AX window filtering if a filter PID is active to avoid junk windows
            if filterPID != nil {
                if !standardFrames.isEmpty || !standardTitles.isEmpty || !standardIDs.isEmpty {
                    var matched = standardIDs.contains(id)
                    
                    if let t = title, !t.isEmpty {
                        if standardTitles.contains(t) {
                            matched = true
                        }
                    }
                    
                    if !matched {
                        for stdFrame in standardFrames {
                            let dx = stdFrame.midX - frame.midX
                            let dy = stdFrame.midY - frame.midY
                            // Match within 25 points distance tolerance
                            if dx*dx + dy*dy < 625 {
                                matched = true
                                break
                            }
                        }
                    }
                    
                    if !matched { return nil }
                } else {
                    // App is running but reports no standard user-facing windows via accessibility
                    return nil
                }
            }

            return DiscoveredWindow(
                id: id,
                ownerPID: pid,
                ownerName: owner,
                title: title,
                frame: frame,
                layer: layer
            )
        }

        cacheLock.lock()
        for window in mapped {
            knownWindows[window.id] = window
        }
        if knownWindows.count > 256 {
            let idsToRemove = Array(knownWindows.keys.prefix(knownWindows.count - 256))
            for id in idsToRemove {
                knownWindows.removeValue(forKey: id)
                persistentThumbnailCache.removeValue(forKey: id)
            }
        }
        cacheLock.unlock()
        return mapped
    }

    /// Prefer normal on-screen windows first (reliable thumbnails), then add off-screen/minimized
    /// surfaces not already listed. Sorting supplemental rows by area avoids surfacing tiny junk windows.
    private func mergedWindowsForDockPreview(
        bundleID: String,
        maxCount: Int,
        includeMinimizedWindows: Bool
    ) -> [DiscoveredWindow] {
        let onScreen = windows(forBundleIdentifier: bundleID)
        guard includeMinimizedWindows else {
            return Array(onScreen.prefix(maxCount))
        }

        var seen = Set<CGWindowID>()
        var result: [DiscoveredWindow] = []
        result.reserveCapacity(maxCount)

        for w in onScreen {
            guard seen.insert(w.id).inserted else { continue }
            result.append(w)
            if result.count >= maxCount { return result }
        }

        // Minimized windows frequently disappear from CGWindowList entirely.
        // AX still exposes them, including their stable WindowServer number,
        // so add those rows before the broader CG fallback.
        for w in minimizedWindowsFromAX(bundleID: bundleID) {
            guard seen.insert(w.id).inserted else { continue }
            result.append(w)
            if result.count >= maxCount { return result }
        }

        let supplementalMinSide: CGFloat = 72
        let supplemental = windowsFromCG(
            options: [.optionAll],
            bundleID: bundleID,
            minimumShortSide: supplementalMinSide
        )
        .filter { !seen.contains($0.id) }
        .sorted {
            Self.windowArea($0) > Self.windowArea($1)
        }

        for w in supplemental {
            guard seen.insert(w.id).inserted else { continue }
            result.append(w)
            if result.count >= maxCount { break }
        }
        return result
    }

    private func minimizedWindowsFromAX(bundleID: String) -> [DiscoveredWindow] {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else { return [] }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return standardAXWindows(of: appElement).compactMap { window in
            var minimizedValue: AnyObject?
            guard AXUIElementCopyAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                &minimizedValue
            ) == .success,
            (minimizedValue as? Bool) == true else { return nil }

            var titleValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = titleValue as? String
            // The old 72x72 minimum could drop a genuine minimized window
            // that happens to be smaller than that. But dropping the floor
            // to >0 let real junk through (shadow/border helper surfaces
            // with tiny but non-zero AX frames), which showed up as garbled
            // extra tiles in the preview panel. 40pt is a middle ground:
            // small enough to keep legitimate compact utility windows,
            // large enough to reject 1-10pt artifacts.
            guard let frame = axFrame(for: window),
                  frame.width >= 40,
                  frame.height >= 40 else { return nil }

            var numberValue: AnyObject?
            let numberStatus = AXUIElementCopyAttributeValue(
                window,
                "AXWindowNumber" as CFString,
                &numberValue
            )
            let reportedID = numberStatus == .success
                ? (numberValue as? NSNumber).map { CGWindowID($0.uint32Value) }
                : nil
            let resolvedID = windowServerID(of: window)
                ?? reportedID
                ?? knownWindowID(pid: app.processIdentifier, title: title, frame: frame)
                ?? syntheticWindowID(pid: app.processIdentifier, title: title, frame: frame)

            return DiscoveredWindow(
                id: resolvedID,
                ownerPID: app.processIdentifier,
                ownerName: app.localizedName ?? bundleID,
                title: title,
                frame: frame,
                layer: 0,
                isMinimized: true
            )
        }
    }

    private func knownWindowID(pid: pid_t, title: String?, frame: CGRect) -> CGWindowID? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return knownWindows.values
            .filter { candidate in
                candidate.ownerPID == pid
                    && (title?.isEmpty != false || candidate.title == title)
            }
            .min { lhs, rhs in
                Self.frameDistance(lhs.frame, frame) < Self.frameDistance(rhs.frame, frame)
            }?.id
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return dx * dx + dy * dy
    }

    private func syntheticWindowID(pid: pid_t, title: String?, frame: CGRect) -> CGWindowID {
        let seed = "\(pid)|\(title ?? "")|\(Int(frame.origin.x))|\(Int(frame.origin.y))|\(Int(frame.width))|\(Int(frame.height))"
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return hash == 0 ? 1 : hash
    }

    private static func windowArea(_ w: DiscoveredWindow) -> CGFloat {
        w.frame.width * w.frame.height
    }

    // MARK: - Snapshots with thumbnails

    /// Returns up to `maxCount` `WindowSnapshot`s for the given bundle, each
    /// with a thumbnail captured (or fetched from cache).
    func windowsWithThumbnails(
        forBundleIdentifier bundleID: String,
        maxCount: Int = 8,
        maxDimension: CGFloat = 320,
        includeMinimizedWindows: Bool = false
    ) -> [WindowSnapshot] {
        let allWindows = mergedWindowsForDockPreview(
            bundleID: bundleID,
            maxCount: maxCount,
            includeMinimizedWindows: includeMinimizedWindows
        )
        let limited = Array(allWindows.prefix(maxCount))
        
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return limited.map { window in
            let thumb = cachedThumbnail(for: window.id)
                ?? captureAndCache(window: window, maxDimension: maxDimension * scale)
            return WindowSnapshot(window: window, thumbnail: thumb)
        }
    }

    // MARK: - Screen Recording permission

    /// `CGWindowListCreateImage` returns `nil` with zero diagnostics when
    /// Screen Recording access hasn't been granted, which is exactly what a
    /// genuinely-empty/offscreen window also returns — from the caller's
    /// side "no thumbnail" and "no permission" look identical. Callers that
    /// want to tell those apart (e.g. to show a real message instead of a
    /// blank preview) should check this first.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording permission prompt if it hasn't
    /// been shown yet. Safe to call repeatedly — it's a no-op once access is
    /// already granted or already denied.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Thumbnail capture

    /// Captures a thumbnail image for a specific window id. Returns `nil`
    /// when the window is offscreen or capture is denied (e.g. Screen
    /// Recording permission missing). Used by the Dock hover preview.
    func captureThumbnail(for windowID: CGWindowID, maxDimension: CGFloat = 320) -> CGImage? {
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .nominalResolution]
        guard let snapshot = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            options
        ) else { return nil }

        let width = CGFloat(snapshot.width)
        let height = CGFloat(snapshot.height)
        let scale = min(maxDimension / max(width, height), 1.0)
        if scale >= 1.0 { return snapshot }
        let targetSize = CGSize(width: width * scale, height: height * scale)
        return snapshot.scaled(to: targetSize) ?? snapshot
    }

    private func cachedThumbnail(for id: CGWindowID) -> CGImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let entry = thumbnailCache[id] else { return nil }
        if CACurrentMediaTime() - entry.timestamp > cacheTTL {
            thumbnailCache.removeValue(forKey: id)
            return nil
        }
        return entry.image
    }

    private func captureAndCache(window: DiscoveredWindow, maxDimension: CGFloat) -> CGImage? {
        if let image = captureThumbnail(for: window.id, maxDimension: maxDimension) {
            let now = CACurrentMediaTime()
            cacheLock.lock()
            thumbnailCache[window.id] = CachedThumbnail(image: image, timestamp: now)
            persistentThumbnailCache[window.id] = image
            cacheLock.unlock()
            return image
        }
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return persistentThumbnailCache[window.id]
    }

    /// Captures every visible app window into the long-lived cache. Minimized
    /// windows can't be captured (macOS stops rendering them), so the only way
    /// to show a real image for one is to have grabbed it while it was still
    /// on screen; running this periodically keeps that cache fresh.
    func warmThumbnailCache(maxDimension: CGFloat = 640) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let candidates = windows().filter { $0.layer == 0 && $0.ownerPID != ownPID }
        for window in candidates.prefix(40) {
            _ = captureAndCache(window: window, maxDimension: maxDimension)
        }
    }

    /// Drops every cached thumbnail. Called when the user disables previews
    /// to keep memory usage minimal.
    func purgeCache() {
        cacheLock.lock()
        thumbnailCache.removeAll()
        persistentThumbnailCache.removeAll()
        knownWindows.removeAll()
        cacheLock.unlock()
    }

    // MARK: - AX-driven window controls

    /// Brings the supplied window to the front and activates its owning
    /// process. Used when the user clicks a thumbnail inside the Dock
    /// preview panel.
    @discardableResult
    func focusWindow(_ window: DiscoveredWindow) -> Bool {
        guard let appElement = matchingAXWindow(for: window) else { return false }

        // Un-minimize first; otherwise `AXRaise` quietly succeeds but leaves
        // the window stowed in the Dock. Treat failure as non-fatal because
        // most non-minimized windows return an error when we set this.
        AXUIElementSetAttributeValue(
            appElement.window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanFalse
        )

        let raise = AXUIElementPerformAction(appElement.window, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: window.ownerPID) {
            app.activate(options: [.activateAllWindows])
        }
        return raise == .success
    }

    /// Minimizes a single window via its AX `AXMinimized` attribute.
    @discardableResult
    func minimizeWindow(_ window: DiscoveredWindow) -> Bool {
        guard let matched = matchingAXWindow(for: window) else { return false }
        return AXUIElementSetAttributeValue(
            matched.window,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    /// Toggles the window's full-screen / zoomed state by pressing the
    /// green traffic light's AX `AXZoomButton` action. Falls back to the
    /// generic `kAXFullScreenAttribute` if the button isn't exposed.
    @discardableResult
    func toggleZoomWindow(_ window: DiscoveredWindow) -> Bool {
        guard let matched = matchingAXWindow(for: window) else { return false }

        var zoomButton: AnyObject?
        if AXUIElementCopyAttributeValue(
            matched.window,
            kAXZoomButtonAttribute as CFString,
            &zoomButton
        ) == .success, let button = AXElementCoercion.element(zoomButton) {
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }

        // Fallback: toggle full-screen attribute directly.
        var current: AnyObject?
        AXUIElementCopyAttributeValue(matched.window, "AXFullScreen" as CFString, &current)
        let isFullscreen = (current as? Bool) ?? false
        return AXUIElementSetAttributeValue(
            matched.window,
            "AXFullScreen" as CFString,
            (isFullscreen ? kCFBooleanFalse : kCFBooleanTrue)!
        ) == .success
    }

    /// Sends the AX close action to the window's close button, equivalent
    /// to clicking the red traffic-light dot. Returns whether the call
    /// succeeded.
    @discardableResult
    func closeWindow(_ window: DiscoveredWindow) -> Bool {
        guard let matched = matchingAXWindow(for: window) else { return false }

        var closeButton: AnyObject?
        let status = AXUIElementCopyAttributeValue(
            matched.window,
            kAXCloseButtonAttribute as CFString,
            &closeButton
        )
        guard status == .success, let buttonElement = AXElementCoercion.element(closeButton) else { return false }
        return AXUIElementPerformAction(buttonElement, kAXPressAction as CFString) == .success
    }

    // MARK: - App-wide window controls

    /// Closes every standard window of the supplied bundle id.
    func closeAllWindows(forBundleIdentifier bundleID: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == bundleID }
        ) else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in standardAXWindows(of: appElement) {
            var closeButton: AnyObject?
            if AXUIElementCopyAttributeValue(
                window,
                kAXCloseButtonAttribute as CFString,
                &closeButton
            ) == .success, let button = AXElementCoercion.element(closeButton) {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
            }
        }
    }

    /// Minimizes every standard window of the supplied bundle id.
    func minimizeAllWindows(forBundleIdentifier bundleID: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == bundleID }
        ) else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for window in standardAXWindows(of: appElement) {
            AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanTrue
            )
        }
    }

    /// Asks an app to terminate. Falls back to forced kill if the polite
    /// terminate is rejected (apps with unsaved-changes prompts that we
    /// can't satisfy from outside the process).
    func terminateApp(bundleIdentifier: String, force: Bool = false) {
        guard let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == bundleIdentifier }
        ) else { return }
        if force {
            app.forceTerminate()
        } else {
            if !app.terminate() {
                // If the polite terminate refused (e.g. a dirty document
                // sheet), follow up with a forced kill so the user gets the
                // result they asked for from the Dock UI.
                app.forceTerminate()
            }
        }
    }

    /// Whether any *standard* (non-sheet, non-utility) window is owned by
    /// the supplied bundle id. Used by the hover gate in `AppDelegate` so
    /// we can skip showing the panel for non-running or window-less apps.
    func hasVisibleStandardWindows(forBundleIdentifier bundleID: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(
            where: { $0.bundleIdentifier == bundleID }
        ) else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        return !standardAXWindows(of: appElement).isEmpty
    }

    /// User-facing windows: standard windows plus dialog-style ones —
    /// Calculator, System Information and many utilities report their main
    /// window as `AXDialog`, and filtering those out made such apps look
    /// window-less (no Dock preview at all once minimized).
    private func standardAXWindows(of appElement: AXUIElement) -> [AXUIElement] {
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue
        ) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return []
        }
        let accepted: Set<String> = [kAXStandardWindowSubrole as String, kAXDialogSubrole as String]
        return windows.filter { window in
            var subroleValue: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
            guard let subrole = subroleValue as? String else { return true }
            return accepted.contains(subrole)
        }
    }

    private struct MatchedAXWindow {
        let window: AXUIElement
    }

    /// Locates the AX element backing a `DiscoveredWindow`.
    ///
    /// `CGWindowID` and AX windows aren't directly bridged, so we match by
    /// owner PID first, then narrow down to the AX window whose frame and
    /// title align with the discovered window.
    private func matchingAXWindow(for window: DiscoveredWindow) -> MatchedAXWindow? {
        let appElement = AXUIElementCreateApplication(window.ownerPID)
        var windowsValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXWindowsAttribute as CFString, &windowsValue
        ) == .success, let axWindows = windowsValue as? [AXUIElement] else {
            return nil
        }

        // Title-based match is cheap and resilient against frame jitter.
        if let title = window.title, !title.isEmpty {
            for ax in axWindows {
                var titleValue: AnyObject?
                if AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &titleValue) == .success,
                   let axTitle = titleValue as? String,
                   axTitle == title {
                    return MatchedAXWindow(window: ax)
                }
            }
        }

        // Fallback: pick the AX window whose frame is closest to the
        // CG-reported frame. This covers untitled windows (e.g. Finder
        // dialogs) and apps that report stale titles via CG.
        var bestMatch: AXUIElement?
        var bestDistance: CGFloat = .infinity
        for ax in axWindows {
            guard let frame = axFrame(for: ax) else { continue }
            let dx = frame.midX - window.frame.midX
            let dy = frame.midY - window.frame.midY
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestMatch = ax
            }
        }
        return bestMatch.map { MatchedAXWindow(window: $0) }
    }

    func hasToggleableWindows(forBundleIdentifier bundleID: String) -> Bool {
        let windows = windowsFromCG(
            options: [.optionAll],
            bundleID: bundleID,
            minimumShortSide: 72
        )
        return !windows.isEmpty
    }

    private func axFrame(for window: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        guard let origin = AXElementCoercion.point(from: positionValue),
              let size = AXElementCoercion.size(from: sizeValue) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

extension WindowDiscoveryService: @unchecked Sendable {}

private extension CGImage {
    /// Bilinear-scaled copy of the receiver. Returns `nil` if Core Graphics
    /// can't allocate the target context (e.g. zero-sized frame).
    func scaled(to size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard
            width > 0,
            height > 0,
            let colorSpace = self.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
