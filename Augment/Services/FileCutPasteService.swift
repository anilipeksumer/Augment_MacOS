import AppKit
import CoreGraphics
import Foundation

/// A true "Cut" for Finder files/folders. Finder natively only offers Copy
/// (⌘C) plus ⌥⌘V to paste-as-move — there's no ⌘X. This adds it: ⌘X while
/// Finder is frontmost marks the current selection, and the next ⌘V moves
/// those items into the frontmost window's folder instead of doing nothing
/// (Finder has no default ⌘V paste-as-copy for a Cut clipboard either).
///
/// Scoped strictly to `NSWorkspace.shared.frontmostApplication` being
/// Finder, so ⌘X/⌘V are left completely untouched in every other app —
/// including normal text/file copy-paste inside Finder itself, which still
/// works exactly as before as long as nothing is pending from a Cut.
@MainActor
final class FileCutPasteService {

    private(set) var isRunning = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var cutChangeCount = NSPasteboard.general.changeCount
    private var cutURLs: [URL] = [] {
        didSet { publishCutSet() }
    }

    /// The last paste, so ⌘Z can move the items back. Finder's own undo
    /// doesn't know about moves Augment made — pressing ⌘Z used to make it
    /// undo something else, or fail with an error.
    private struct MoveRecord {
        let moves: [(from: URL, to: URL)]
        let date: Date
    }
    private var lastMove: MoveRecord?
    private static let undoWindow: TimeInterval = 10 * 60

    private static let cutKeyCode: UInt16 = 7   // 'x'
    private static let pasteKeyCode: UInt16 = 9 // 'v'
    private static let undoKeyCode: UInt16 = 6  // 'z'
    private static let copyKeyCode: UInt16 = 8  // 'c'
    private static let escapeKeyCode: UInt16 = 53
    private static let finderBundleID = "com.apple.finder"

    func start() {
        guard !isRunning else { return }
        installEventTap()
    }

    func stop() {
        guard isRunning else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        cutURLs.removeAll()
        lastMove = nil
    }

    // MARK: - Event tap

    private func installEventTap() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<FileCutPasteService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Augment: FileCutPasteService – failed to create event tap (Accessibility?)")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderBundleID else {
            return Unmanaged.passUnretained(event)
        }

        // A newly copied screenshot/text/file supersedes an older Cut.
        if !cutURLs.isEmpty && NSPasteboard.general.changeCount != cutChangeCount {
            cutURLs = []
            lastMove = nil
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        // Esc drops a pending cut, like Windows; Finder still gets the key.
        if keyCode == Self.escapeKeyCode && flags.isEmpty && !cutURLs.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.cutURLs = [] }
            return Unmanaged.passUnretained(event)
        }

        guard flags == .maskCommand else { return Unmanaged.passUnretained(event) }

        switch keyCode {
        case Self.cutKeyCode:
            DispatchQueue.main.async { [weak self] in self?.markSelectionForCut() }
            return nil
        case Self.pasteKeyCode where !cutURLs.isEmpty:
            // Only steal ⌘V when something is cut — otherwise Finder's own
            // paste (regular copy) behaves exactly as normal.
            DispatchQueue.main.async { [weak self] in self?.pasteAsMove() }
            return nil
        case Self.undoKeyCode where !cutURLs.isEmpty:
            // Undo before pasting just cancels the cut.
            DispatchQueue.main.async { [weak self] in self?.cutURLs = [] }
            return nil
        case Self.undoKeyCode where canUndoLastMove:
            DispatchQueue.main.async { [weak self] in self?.undoLastMove() }
            return nil
        case Self.undoKeyCode:
            return Unmanaged.passUnretained(event)
        default:
            // Any other Finder command (copy, duplicate, trash, …) becomes
            // the newest thing to undo, so ⌘Z belongs to Finder again.
            lastMove = nil
            if keyCode == Self.copyKeyCode && !cutURLs.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.cutURLs = [] }
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private var canUndoLastMove: Bool {
        guard let lastMove, Date().timeIntervalSince(lastMove.date) < Self.undoWindow else { return false }
        return lastMove.moves.contains { FileManager.default.fileExists(atPath: $0.to.path) }
    }

    // MARK: - Cut / paste

    private func markSelectionForCut() {
        let changeCount = NSPasteboard.general.changeCount
        let script = """
        tell application "Finder"
            set sel to selection
            set out to ""
            repeat with i in sel
                set out to out & (POSIX path of (i as alias)) & "\\n"
            end repeat
            return out
        end tell
        """
        Self.runAppleScriptAsync(script) { [weak self] raw in
            guard let self else { return }
            guard NSPasteboard.general.changeCount == changeCount else { return }
            self.cutChangeCount = changeCount
            self.lastMove = nil
            self.cutURLs = (raw ?? "")
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
            if !self.cutURLs.isEmpty { NSSound(named: "Pop")?.play() }
        }
    }

    private func pasteAsMove() {
        let pending = cutURLs
        cutURLs = []
        guard !pending.isEmpty else { return }

        let script = """
        tell application "Finder"
            try
                return POSIX path of (target of front window as alias)
            on error
                return POSIX path of (path to desktop)
            end try
        end tell
        """
        Self.runAppleScriptAsync(script) { [weak self] destPath in
            guard let self, let destPath else { return }
            self.move(pending, into: URL(fileURLWithPath: destPath, isDirectory: true))
        }
    }

    private func move(_ pending: [URL], into destDir: URL) {
        var moves: [(from: URL, to: URL)] = []
        var failures: [String] = []
        for source in pending {
            guard source.deletingLastPathComponent().standardizedFileURL != destDir.standardizedFileURL else {
                continue // already in the destination folder
            }
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = Self.nonCollidingURL(for: source.lastPathComponent, in: destDir)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                moves.append((source, destination))
            } catch {
                NSLog("Augment: FileCutPasteService – move failed for %@: %@", source.path, error.localizedDescription)
                failures.append(source.lastPathComponent)
            }
        }
        lastMove = moves.isEmpty ? nil : MoveRecord(moves: moves, date: Date())
        if !moves.isEmpty {
            selectInFinder(moves.map(\.to))
            NSSound(named: "Pop")?.play()
        }
        if !failures.isEmpty {
            NSSound.beep()
        }
    }

    /// Moves the last pasted items back where they were cut from.
    private func undoLastMove() {
        guard let record = lastMove else { return }
        lastMove = nil
        var restored: [URL] = []
        for move in record.moves.reversed() {
            guard FileManager.default.fileExists(atPath: move.to.path) else { continue }
            let back = Self.nonCollidingURL(for: move.from.lastPathComponent, in: move.from.deletingLastPathComponent())
            do {
                try FileManager.default.moveItem(at: move.to, to: back)
                restored.append(back)
            } catch {
                NSLog("Augment: FileCutPasteService – undo failed for %@: %@", move.to.path, error.localizedDescription)
                NSSound.beep()
            }
        }
        if !restored.isEmpty { NSSound(named: "Pop")?.play() }
    }

    /// "Name.ext", or "Name 2.ext", "Name 3.ext", … if that's taken — the
    /// way Finder names a clash instead of refusing the paste.
    private static func nonCollidingURL(for name: String, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        for n in 2...999 {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let url = directory.appendingPathComponent(next)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return directory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private func selectInFinder(_ urls: [URL]) {
        let list = urls.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        Self.runAppleScriptAsync("tell application \"Finder\" to select {\(list)}") { _ in }
    }

    /// Shares the cut set with the Finder extension, which badges those
    /// items (Finder has no API to dim an icon the way Windows does).
    private func publishCutSet() {
        let paths = cutURLs.map(\.path) as CFArray
        AppGroup.setSuiteValue(cutURLs.isEmpty ? nil : paths, forKey: AppGroupKey.fileCutPaths)
        DistributedNotificationCenter.default().postNotificationName(
            AppGroup.fileCutChangedNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    // MARK: - AppleScript

    /// Runs AppleScript off the main thread and hands the result back on
    /// main. Never waits on the main thread: the key tap lives there, so a
    /// slow Finder reply would otherwise hold up every key press.
    private static func runAppleScriptAsync(_ source: String, completion: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var value: String?
            if let script = NSAppleScript(source: source) {
                var errorInfo: NSDictionary?
                value = script.executeAndReturnError(&errorInfo).stringValue
                if let errorInfo { NSLog("Augment: FileCutPasteService – AppleScript error %@", errorInfo) }
            }
            let result = (value?.isEmpty == false) ? value : nil
            DispatchQueue.main.async { completion(result) }
        }
    }
}
