import AppKit
import QuartzCore
import Combine
import CoreGraphics
import IOKit

/// One connected screen and how Augment can change its brightness.
struct ManagedDisplay: Identifiable, Equatable {
    enum Method: Equatable {
        /// macOS's own control (built-in panels, Apple displays).
        case native
        /// DDC/CI over the cable, like MonitorControl — most third-party monitors.
        case ddc
        /// Dimming the picture (gamma) when the monitor can't be controlled.
        case software
    }

    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let method: Method
    var brightness: Double
}

/// Brightness for every connected display — the MonitorControl idea:
/// native where macOS allows it, DDC/CI for other monitors, and software
/// dimming as the last resort so every screen gets a working slider.
@MainActor
final class DisplayBrightnessService: ObservableObject {
    static let shared = DisplayBrightnessService()

    @Published private(set) var displays: [ManagedDisplay] = [] {
        didSet {
            let methods = Dictionary(displays.map { ($0.id, $0.method) }, uniquingKeysWith: { a, _ in a })
            Self.snapshotLock.lock()
            Self.methodSnapshot = methods
            Self.snapshotLock.unlock()
        }
    }

    /// Read from the event-tap thread without waiting on the main thread.
    private nonisolated(unsafe) static var methodSnapshot: [CGDirectDisplayID: ManagedDisplay.Method] = [:]
    private nonisolated static let snapshotLock = NSLock()

    nonisolated static func method(for id: CGDirectDisplayID) -> ManagedDisplay.Method? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return methodSnapshot[id]
    }

    nonisolated static var firstDDCDisplay: CGDirectDisplayID? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return methodSnapshot.first { $0.value == .ddc }?.key
    }

    /// DDC services keyed by display, found by matching IORegistry
    /// framebuffer attributes against CoreGraphics' vendor/model/serial.
    private var ddcServices: [CGDirectDisplayID: AnyObject] = [:]
    private let ddcQueue = DispatchQueue(label: "com.augment.ddc", qos: .userInitiated)
    private var pendingDDC: [CGDirectDisplayID: Double] = [:]
    private var softwareLevels: [CGDirectDisplayID: Double] = [:]
    private var observer: Any?

    private init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Discovery

    func refresh() {
        ddcServices = Self.matchDDCServices()
        var result: [ManagedDisplay] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let method: ManagedDisplay.Method
            var level: Double
            if Self.canChangeNative(id), let value = Self.nativeBrightness(id) {
                method = .native
                level = Double(value)
            } else if ddcServices[id] != nil {
                method = .ddc
                level = Self.storedLevel(for: id) ?? 0.5
                if let read = readDDCBrightness(id) { level = read }
            } else {
                method = .software
                level = softwareLevels[id] ?? 1
            }
            result.append(ManagedDisplay(id: id, name: screen.localizedName, isBuiltIn: builtIn,
                                         method: method, brightness: level))
        }
        // Built-in first, then the rest left to right as arranged.
        displays = result.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return CGDisplayBounds(a.id).minX < CGDisplayBounds(b.id).minX
        }
    }

    /// Test/diagnostic summary: matched DDC services and a live read.
    func debugDDCSummary() -> String {
        var parts = ["ddcServices=\(ddcServices.keys.map { String($0) })"]
        for (id, service) in ddcServices {
            let read = DDC.read(service: service, code: 0x10)
            parts.append("read[\(id)]=\(read.map { "\($0.0)/\($0.1)" } ?? "nil")")
        }
        parts.append("nativeCanChange=\(displays.map { "\($0.id):\(Self.canChangeNative($0.id))" })")
        return parts.joined(separator: " ")
    }

    func display(for screen: NSScreen?) -> ManagedDisplay? {
        guard let id = screen?.displayID else { return nil }
        return displays.first { $0.id == id }
    }

    // MARK: - Setting

    func setBrightness(_ value: Double, for id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, 0), 1)
        displays[index].brightness = clamped
        switch displays[index].method {
        case .native:
            _ = Self.setNative(id, Float(clamped))
        case .ddc:
            Self.storeLevel(clamped, for: id)
            scheduleDDCWrite(clamped, for: id)
        case .software:
            softwareLevels[id] = clamped
            Self.applyGamma(clamped, to: id)
        }
    }

    /// Sets every display at once (the quick panel's "All" slider, schedules).
    func setAll(_ value: Double, animated: Bool = false) {
        for display in displays {
            if animated { animateBrightness(to: value, for: display.id, duration: 1.2) }
            else { setBrightness(value, for: display.id) }
        }
    }

    private var animations: [CGDirectDisplayID: Timer] = [:]
    private var targets: [CGDirectDisplayID: Double] = [:]

    /// Glides to `target` the way macOS's own brightness keys do, instead
    /// of jumping. DDC monitors get fewer, coalesced writes.
    func animateBrightness(to target: Double, for id: CGDirectDisplayID, duration: Double = 0.22) {
        guard let display = displays.first(where: { $0.id == id }) else { return }
        let clamped = min(max(target, 0), 1)
        let start = display.brightness
        targets[id] = clamped
        animations[id]?.invalidate()
        let begin = CACurrentMediaTime()
        let interval = display.method == .ddc ? 1.0 / 20 : 1.0 / 60
        let timer = Timer(timeInterval: interval, repeats: true) { timer in
            MainActor.assumeIsolated {
                let service = DisplayBrightnessService.shared
                let p = min(1, (CACurrentMediaTime() - begin) / duration)
                let eased = 1 - pow(1 - p, 3)
                service.setBrightness(start + (clamped - start) * eased, for: id)
                if p >= 1 {
                    timer.invalidate()
                    service.animations[id] = nil
                    service.targets[id] = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animations[id] = timer
    }

    /// Moves one display's brightness by `delta` (keyboard keys) and
    /// returns the new level.
    @discardableResult
    func step(_ delta: Double, for id: CGDirectDisplayID) -> Double? {
        guard let display = displays.first(where: { $0.id == id }) else { return nil }
        // Build on the level we're already heading to, so quick repeated
        // presses add up instead of fighting the running animation.
        let base = targets[id] ?? display.brightness
        let value = min(max(base + delta, 0), 1)
        animateBrightness(to: value, for: id)
        return value
    }

    // MARK: - Monitor speakers over DDC

    /// Displays whose speakers can be driven over DDC (VCP 0x62).
    var ddcDisplayIDs: [CGDirectDisplayID] { displays.filter { $0.method == .ddc }.map(\.id) }

    func ddcVolume(for id: CGDirectDisplayID) -> Double {
        UserDefaults.standard.object(forKey: "augment.ddcVolume.\(id)") as? Double ?? 0.5
    }

    func setDDCVolume(_ value: Double, for id: CGDirectDisplayID) {
        guard let service = ddcServices[id] else { return }
        let clamped = min(max(value, 0), 1)
        UserDefaults.standard.set(clamped, forKey: "augment.ddcVolume.\(id)")
        let box = UncheckedSendable(service)
        ddcQueue.async { DDC.write(service: box.value, code: 0x62, value: UInt16(clamped * 100)) }
    }

    func setDDCMuted(_ muted: Bool, for id: CGDirectDisplayID) {
        guard let service = ddcServices[id] else { return }
        let box = UncheckedSendable(service)
        ddcQueue.async { DDC.write(service: box.value, code: 0x8D, value: muted ? 1 : 2) }
    }

    /// Puts every software-dimmed screen back to normal (on quit).
    func restoreSoftwareDimming() {
        guard !softwareLevels.isEmpty else { return }
        CGDisplayRestoreColorSyncSettings()
        softwareLevels.removeAll()
    }

    /// DDC is slow (tens of ms per write) — while a slider is dragged only
    /// the latest value per display is sent.
    private func scheduleDDCWrite(_ value: Double, for id: CGDirectDisplayID) {
        let isIdle = pendingDDC[id] == nil
        pendingDDC[id] = value
        guard isIdle, let service = ddcServices[id] else { return }
        let box = UncheckedSendable(service)
        ddcQueue.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            Task { @MainActor in
                guard let self, let latest = self.pendingDDC.removeValue(forKey: id) else { return }
                let level = UInt16(latest * 100)
                self.ddcQueue.async {
                    DDC.write(service: box.value, code: 0x10, value: level)
                }
            }
        }
    }

    private func readDDCBrightness(_ id: CGDirectDisplayID) -> Double? {
        guard let service = ddcServices[id], let (current, maximum) = DDC.read(service: service, code: 0x10),
              maximum > 0 else { return nil }
        return Double(current) / Double(maximum)
    }

    // MARK: - Native (DisplayServices)

    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServices =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices", RTLD_NOW)
    private static let canChangeFn: CanChangeFn? = displayServices
        .flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: CanChangeFn.self) }
    private static let getFn: GetFn? = displayServices
        .flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = displayServices
        .flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }

    private static func canChangeNative(_ id: CGDirectDisplayID) -> Bool {
        canChangeFn?(id) ?? (CGDisplayIsBuiltin(id) != 0)
    }

    static func nativeBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        return getFn(id, &value) == 0 ? value : nil
    }

    @discardableResult
    static func setNative(_ id: CGDirectDisplayID, _ value: Float) -> Bool {
        setFn?(id, value) == 0
    }

    // MARK: - Software dimming

    private static func applyGamma(_ level: Double, to id: CGDirectDisplayID) {
        // Never fully black: keep at least 15% so the screen stays usable.
        let maxValue = CGGammaValue(0.15 + 0.85 * level)
        CGSetDisplayTransferByFormula(id, 0, maxValue, 1, 0, maxValue, 1, 0, maxValue, 1)
    }

    // MARK: - Remembered DDC levels (most monitors can't be read reliably)

    private static func storedLevel(for id: CGDirectDisplayID) -> Double? {
        let key = "augment.ddcLevel.\(CGDisplayVendorNumber(id)).\(CGDisplayModelNumber(id)).\(CGDisplaySerialNumber(id))"
        return UserDefaults.standard.object(forKey: key) as? Double
    }

    private static func storeLevel(_ value: Double, for id: CGDirectDisplayID) {
        let key = "augment.ddcLevel.\(CGDisplayVendorNumber(id)).\(CGDisplayModelNumber(id)).\(CGDisplaySerialNumber(id))"
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: - Matching DDC services to displays

    /// Walks the IORegistry in order. Each external framebuffer node
    /// ("AppleCLCD2" / "IOMobileFramebufferShim") carries the monitor's
    /// vendor/product/serial; the "DCPAVServiceProxy" that follows it is that
    /// monitor's DDC channel. (The built-in panel's proxy is "Embedded".)
    private static func matchDDCServices() -> [CGDirectDisplayID: AnyObject] {
        guard let create = DDCPrivateSymbols.createWithService else { return [:] }
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &onlineIDs, &count)
        let externals = onlineIDs.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
        guard !externals.isEmpty else { return [:] }

        struct Candidate { let service: AnyObject; let vendor: UInt32?; let product: UInt32?; let serial: UInt32? }
        var candidates: [Candidate] = []

        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iterator) }

        var lastAttributes: [String: Any]?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &nameBuffer)
            let name = String(cString: nameBuffer)
            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any]
                lastAttributes = attributes?["ProductAttributes"] as? [String: Any]
            } else if name == "DCPAVServiceProxy" {
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
                defer { lastAttributes = nil }
                guard location == "External", let service = create(nil, entry)?.takeRetainedValue() else { continue }
                candidates.append(Candidate(
                    service: service,
                    vendor: (lastAttributes?["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                    product: (lastAttributes?["ProductID"] as? NSNumber)?.uint32Value,
                    serial: (lastAttributes?["SerialNumber"] as? NSNumber)?.uint32Value
                ))
            }
        }

        var result: [CGDirectDisplayID: AnyObject] = [:]
        var remaining = candidates
        for id in externals {
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
            if let i = remaining.firstIndex(where: { $0.vendor == vendor && $0.product == model && ($0.serial == nil || $0.serial == serial || serial == 0) })
                ?? remaining.firstIndex(where: { $0.vendor == vendor && $0.product == model }) {
                result[id] = remaining.remove(at: i).service
            }
        }
        // One monitor, one channel: pair them even if attributes were missing.
        if result.isEmpty, externals.count == 1, candidates.count == 1 {
            result[externals[0]] = candidates[0].service
        }
        return result
    }
}

private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// VESA DDC/CI framing over Apple Silicon's IOAVService I²C channel.
/// The host address (0x51) goes in the call's data-address argument, not in
/// the buffer; the checksum still covers it (0x6E ^ 0x51 ^ payload).
enum DDC {
    private static let chip: UInt32 = 0x37
    private static let hostAddress: UInt32 = 0x51
    private static let checksumSeed: UInt8 = 0x6E ^ 0x51

    static func write(service: AnyObject, code: UInt8, value: UInt16) {
        guard let writeI2C = DDCPrivateSymbols.writeI2C else { return }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        packet.append(packet.reduce(checksumSeed) { $0 ^ $1 })
        let count = UInt32(packet.count)
        // Monitors drop writes now and then; send twice like MonitorControl.
        for _ in 0..<2 {
            let result = packet.withUnsafeMutableBytes { buffer in
                writeI2C(service, chip, hostAddress, buffer.baseAddress!, count)
            }
            if result != kIOReturnSuccess { NSLog("Augment: DDC write failed (%d)", result) }
            usleep(20_000)
        }
    }

    /// "Get VCP Feature": returns (current, maximum) or nil.
    static func read(service: AnyObject, code: UInt8) -> (UInt16, UInt16)? {
        guard let writeI2C = DDCPrivateSymbols.writeI2C, let readI2C = DDCPrivateSymbols.readI2C else { return nil }
        var request: [UInt8] = [0x82, 0x01, code]
        request.append(request.reduce(checksumSeed) { $0 ^ $1 })
        let requestCount = UInt32(request.count)
        for _ in 0..<3 {
            let wrote = request.withUnsafeMutableBytes { buffer in
                writeI2C(service, chip, hostAddress, buffer.baseAddress!, requestCount)
            }
            guard wrote == kIOReturnSuccess else { usleep(20_000); continue }
            usleep(50_000)
            var reply = [UInt8](repeating: 0, count: 12)
            let read = reply.withUnsafeMutableBytes { buffer in
                readI2C(service, chip, hostAddress, buffer.baseAddress!, 12)
            }
            // Reply: [src, len, 0x02, result, code, type, maxHi, maxLo, curHi, curLo, chk]
            guard read == kIOReturnSuccess, reply[2] == 0x02, reply[3] == 0x00, reply[4] == code else { continue }
            let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, maximum)
        }
        return nil
    }
}
