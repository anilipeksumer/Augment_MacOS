import AppKit
import CoreFoundation
import Foundation

@MainActor
final class FinderBridgeService {
    private struct DrainResult: Sendable {
        var createdURLs: [URL] = []
        var revealURLs: [URL] = []
    }

    private var pollTimer: Timer?
    private var distributedRevealObserver: NSObjectProtocol?
    private var isProcessingQueues = false

    func start() {
        registerObservers()
        processQueues()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.processQueues()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.processQueues()
        }
        startPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
        if let distributedRevealObserver {
            DistributedNotificationCenter.default().removeObserver(distributedRevealObserver)
            self.distributedRevealObserver = nil
        }
    }

    func processQueues() {
        guard !isProcessingQueues else { return }
        isProcessingQueues = true
        let extensionBundleURL = Self.augmentFinderExtensionBundleURL()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.drainQueues(extensionBundleURL: extensionBundleURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessingQueues = false
                Self.apply(result)
            }
        }
    }

    private func registerObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                let service = Unmanaged<FinderBridgeService>.fromOpaque(observer).takeUnretainedValue()
                let received = name.rawValue as String
                if received == FinderCreateBridge.darwinNotificationName.rawValue as String {
                    DispatchQueue.main.async { service.processQueues() }
                } else if received == FinderRevealBridge.darwinNotificationName.rawValue as String {
                    DispatchQueue.main.async { service.processQueues() }
                }
            },
            nil,
            nil,
            .deliverImmediately
        )

        if distributedRevealObserver == nil {
            distributedRevealObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(FinderRevealBridge.darwinNotificationName.rawValue as String),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.processQueues()
                }
            }
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.processQueues()
            }
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    private nonisolated static func augmentFinderExtensionBundleURL() -> URL? {
        if let pluginsPath = Bundle.main.builtInPlugInsPath {
            let extURL = URL(fileURLWithPath: pluginsPath, isDirectory: true)
                .appendingPathComponent("AugmentFinder.appex", isDirectory: true)
            if Bundle(url: extURL) != nil { return extURL }
        }
        let plugIns = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/AugmentFinder.appex")
        return Bundle(url: plugIns) == nil ? nil : plugIns
    }

    private nonisolated static func drainQueues(extensionBundleURL: URL?) -> DrainResult {
        var result = DrainResult()
        result.createdURLs = processCreateQueue(extensionBundleURL: extensionBundleURL)
        result.revealURLs = processRevealQueue()
        return result
    }

    private static func apply(_ result: DrainResult) {
        if let lastCreated = result.createdURLs.last {
            NSWorkspace.shared.activateFileViewerSelecting([lastCreated])
            
            // Give Finder a moment to bring the window forward and select the file,
            // then simulate the Return key to enter inline rename mode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let returnCode: CGKeyCode = 0x24 // Return
                let src = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: returnCode, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: returnCode, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
        }
        for url in result.revealURLs {
            NSWorkspace.shared.selectFile(
                url.path,
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path
            )
        }
    }

    private nonisolated static func processCreateQueue(extensionBundleURL: URL?) -> [URL] {
        guard let queueDir = FinderCreateBridge.queueDirectory else {
            NSLog("Augment: Finder create bridge - missing App Group queue directory.")
            return []
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: queueDir.path),
              !names.isEmpty else { return [] }

        guard let extensionBundleURL, let extBundle = Bundle(url: extensionBundleURL) else {
            NSLog("Augment: Finder create bridge - AugmentFinder.appex bundle not found.")
            return []
        }

        let templates = FileTemplateFactory.allTemplates()
        var created: [URL] = []

        for name in queuePlistNames(from: names) {
            let fileURL = queueDir.appendingPathComponent(name)
            guard let req: FinderCreateBridge.Request = decodeRequest(at: fileURL) else {
                removeQueueFile(fileURL)
                continue
            }
            guard templates.indices.contains(req.templateTag) else {
                removeQueueFile(fileURL)
                continue
            }
            do {
                let createdURL = try FileTemplateWriter.create(
                    template: templates[req.templateTag],
                    in: URL(fileURLWithPath: req.directoryPath, isDirectory: true),
                    bundle: extBundle
                )
                created.append(createdURL)
                removeQueueFile(fileURL)
            } catch {
                retryOrDrop(req, originalFileURL: fileURL, queueDir: queueDir, error: error)
            }
        }

        return created
    }

    private nonisolated static func processRevealQueue() -> [URL] {
        guard let queueDir = FinderRevealBridge.queueDirectory else {
            NSLog("Augment: Finder reveal bridge - missing App Group queue directory.")
            return []
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: queueDir.path),
              !names.isEmpty else { return [] }

        var revealURLs: [URL] = []
        for name in queuePlistNames(from: names) {
            let fileURL = queueDir.appendingPathComponent(name)
            guard let req: FinderRevealBridge.Request = decodeRequest(at: fileURL) else {
                removeQueueFile(fileURL)
                continue
            }

            let pathURL = URL(fileURLWithPath: req.filePath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: pathURL.path, isDirectory: &isDir) {
                revealURLs.append(pathURL)
            } else {
                NSLog("Augment: Finder reveal bridge - file does not exist at %@", pathURL.path)
            }
            removeQueueFile(fileURL)
        }
        return revealURLs
    }

    private nonisolated static func decodeRequest<T: Decodable>(at fileURL: URL) -> T? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(T.self, from: data)
    }

    private nonisolated static func queuePlistNames(from names: [String]) -> [String] {
        names
            .filter { ($0 as NSString).pathExtension == "plist" }
            .sorted()
            .prefix(40)
            .map { $0 }
    }

    private nonisolated static func retryOrDrop(
        _ request: FinderCreateBridge.Request,
        originalFileURL: URL,
        queueDir: URL,
        error: Error
    ) {
        NSLog("Augment: Finder create bridge failed: %@", error.localizedDescription)
        guard request.attempt < 2 else {
            removeQueueFile(originalFileURL)
            return
        }
        var retry = request
        retry.attempt += 1
        let retryURL = queueDir.appendingPathComponent("\(UUID().uuidString).plist")
        do {
            let data = try PropertyListEncoder().encode(retry)
            try data.write(to: retryURL, options: [.atomic])
            removeQueueFile(originalFileURL)
        } catch {
            NSLog("Augment: Finder create bridge retry enqueue failed: %@", error.localizedDescription)
        }
    }

    private nonisolated static func removeQueueFile(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
