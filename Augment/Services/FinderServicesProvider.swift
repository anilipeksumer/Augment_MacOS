import AppKit

/// Finder right-click items delivered through macOS Services. Finder Sync
/// extensions aren't consulted inside iCloud Drive (or an iCloud-synced
/// Desktop / Documents), but Services work on any file, so the most used
/// items are offered this way too (right-click › Services).
@MainActor
final class FinderServicesProvider: NSObject {
    static let shared = FinderServicesProvider()

    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    private func urls(from pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func copyPath(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let paths = urls(from: pboard).map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    @objc func openInTerminal(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = urls(from: pboard).first,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func newTextFile(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let url = urls(from: pboard).first else { return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
        let base = Localizer.string("finder.new_text_name")
        var file = folder.appendingPathComponent("\(base).txt")
        var n = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent("\(base) \(n).txt"); n += 1
        }
        guard FileManager.default.createFile(atPath: file.path, contents: Data()) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
