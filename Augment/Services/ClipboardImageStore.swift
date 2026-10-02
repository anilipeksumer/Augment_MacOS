import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Image bytes live outside the preferences plist. Names are content hashes,
/// so the same screenshot arriving from disk and the pasteboard shares a file.
struct ClipboardImageStore {
    static let maxImageBytes = 32 * 1024 * 1024
    static let maxTotalBytes = 200 * 1024 * 1024
    static var defaultDirectory: URL {
        AppGroup.sharedDirectory.appendingPathComponent("ClipboardImages", isDirectory: true)
    }
    let directory: URL

    static func data(from pasteboard: NSPasteboard) -> Data? {
        // Copying a file should keep Finder's ordinary file paste behavior.
        guard pasteboard.availableType(from: [.fileURL]) == nil else { return nil }
        guard let type = pasteboard.availableType(from: [.png, .tiff]),
              let data = pasteboard.data(forType: type), data.count <= maxImageBytes else { return nil }
        return data
    }

    static func pngData(_ data: Data) -> Data? {
        guard data.count <= maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 64_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maxImageBytes else { return nil }
        return output as Data
    }

    func save(_ data: Data) throws -> String {
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
        return name
    }

    func url(for name: String) -> URL? {
        let hash = name.dropLast(4)
        guard name.hasSuffix(".png"), hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    func prune(keeping names: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in contents where url(for: file.lastPathComponent) != nil && !names.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func thumbnail(named name: String) -> NSImage? {
        guard let url = url(for: name), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    /// Exclusive creation prevents overwriting even if another process creates
    /// a file between choosing the name and writing it.
    static func writePNG(_ data: Data, to directory: URL, baseName: String) throws -> URL {
        for index in 1...10000 {
            let name = baseName + (index == 1 ? "" : " \(index)") + ".png"
            let url = directory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: [.withoutOverwriting])
                return url
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
