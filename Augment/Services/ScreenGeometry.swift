import AppKit
import CoreGraphics
import Foundation

/// Lightweight, persistable description of an `NSScreen`.
///
/// Stores the display ID alongside the localized name so the user-selected
/// "lock to this display" identifier survives small reconfigurations like
/// arrange-mirror toggles. Matching falls back to localized name when the
/// underlying display ID changes.
struct ScreenIdentity: Hashable, Identifiable {
    let displayID: CGDirectDisplayID
    let localizedName: String

    var id: String { storageKey }

    /// Stable key used in `SharedPreferences.lockedScreenIdentifiers`.
    var storageKey: String {
        "\(localizedName)#\(displayID)"
    }

    init(displayID: CGDirectDisplayID, localizedName: String) {
        self.displayID = displayID
        self.localizedName = localizedName
    }

    /// Decodes a `storageKey` into an identity. Returns `nil` for malformed
    /// strings so persisted preferences from older builds can be skipped
    /// silently.
    static func parse(storageKey: String) -> ScreenIdentity? {
        guard let hashIndex = storageKey.lastIndex(of: "#") else { return nil }
        let name = String(storageKey[..<hashIndex])
        let idString = String(storageKey[storageKey.index(after: hashIndex)...])
        guard let id = CGDirectDisplayID(idString) else { return nil }
        return ScreenIdentity(displayID: id, localizedName: name)
    }
}

/// Helpers for translating `NSScreen` instances to `ScreenIdentity` and back.
enum ScreenGeometry {

    /// Identity of the supplied screen, or `nil` if no display ID is exposed.
    static func identity(of screen: NSScreen) -> ScreenIdentity? {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        let name: String
        if #available(macOS 10.15, *) {
            name = screen.localizedName
        } else {
            name = "Display \(displayID.uint32Value)"
        }
        return ScreenIdentity(
            displayID: CGDirectDisplayID(displayID.uint32Value),
            localizedName: name
        )
    }

    /// Returns every connected screen's identity, in the order macOS exposes
    /// them (primary first).
    static func allIdentities() -> [ScreenIdentity] {
        NSScreen.screens.compactMap(identity(of:))
    }

    /// Locates the `NSScreen` that currently contains the supplied AppKit
    /// global point (origin at the bottom-left of the primary display).
    static func screen(containing point: CGPoint) -> NSScreen? {
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return exact
        }
        return NSScreen.main
    }

    /// Locates the `NSScreen` that contains the supplied CoreGraphics
    /// event point (origin at the top-left of the primary display).
    ///
    /// `CGEvent.location` and `NSScreen.frame` use opposite Y axes on
    /// macOS, so calling `frame.contains(point)` directly with a CG point
    /// silently picks the wrong screen on every multi-display setup. This
    /// helper converts first, then delegates to `screen(containing:)`.
    static func screen(containingCGPoint point: CGPoint) -> NSScreen? {
        screen(containing: convertFromCG(point))
    }

    /// Whether `point` (CG event coordinates) falls within any of the
    /// user-locked displays.
    static func isCGPoint(
        _ point: CGPoint,
        onAnyOf identities: [ScreenIdentity]
    ) -> Bool {
        guard !identities.isEmpty else { return true }
        guard let screen = screen(containingCGPoint: point),
              let identity = identity(of: screen) else { return false }
        return identities.contains(where: { match($0, identity) })
    }

    /// Converts a CoreGraphics global point (top-left origin) to an
    /// AppKit global point (bottom-left origin, primary screen anchored
    /// at the origin). `appKit.y = primaryHeight - cg.y`.
    static func convertFromCG(_ point: CGPoint) -> CGPoint {
        flipY(point)
    }

    /// Converts an AppKit global point to a CoreGraphics global point.
    /// The operation is the inverse of `convertFromCG` and uses the same
    /// formula since both flips share the primary screen's height.
    static func convertToCG(_ point: CGPoint) -> CGPoint {
        flipY(point)
    }

    private static func flipY(_ point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Selects the best-matching screen for the supplied identity list,
    /// preferring an exact display-ID match and falling back to the
    /// localized name. Returns `NSScreen.main` if neither matches – callers
    /// can decide whether that's an acceptable fallback.
    static func bestScreen(
        for identities: [ScreenIdentity]
    ) -> NSScreen? {
        let allScreens = NSScreen.screens
        for identity in identities {
            if let exact = allScreens.first(where: {
                ScreenGeometry.identity(of: $0)?.displayID == identity.displayID
            }) {
                return exact
            }
            if let nameMatch = allScreens.first(where: {
                ScreenGeometry.identity(of: $0)?.localizedName == identity.localizedName
            }) {
                return nameMatch
            }
        }
        return NSScreen.main
    }

    /// Soft equality between two identities – matches on display ID *or*
    /// name, so reconfiguring monitors doesn't silently drop user choices.
    static func match(_ lhs: ScreenIdentity, _ rhs: ScreenIdentity) -> Bool {
        if lhs.displayID == rhs.displayID { return true }
        return lhs.localizedName == rhs.localizedName
    }
}
