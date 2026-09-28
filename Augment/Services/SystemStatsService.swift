import Darwin
import Foundation
import IOKit

/// CPU, memory, network and temperature for the quick panel (the Stats /
/// iStat Menus idea). Samples every 2 s, and only while something is
/// showing it, so it costs nothing the rest of the time.
@MainActor
final class SystemStatsService: ObservableObject {
    static let shared = SystemStatsService()

    struct Snapshot: Equatable {
        var cpu: Double = 0                 // 0...1
        var cpuHistory: [Double] = []       // last minute
        var memoryUsed: UInt64 = 0          // bytes
        var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
        var downBytesPerSecond: Double = 0
        var upBytesPerSecond: Double = 0
        var temperature: Double?            // °C, when sensors are readable
        var thermalState: ProcessInfo.ThermalState = .nominal
        /// When the last sample landed (drives the sparkline's scroll).
        var updatedAt: Date = .distantPast
    }

    @Published private(set) var snapshot = Snapshot()

    private var timer: Timer?
    private var users = 0
    private let sampler = Sampler()
    private let queue = DispatchQueue(label: "com.augment.stats", qos: .utility)

    /// Call when a view that shows stats appears / disappears.
    func retain() {
        users += 1
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in SystemStatsService.shared.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let sampler = self.sampler
        queue.async {
            let reading = sampler.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let service = SystemStatsService.shared
                    var next = service.snapshot
                    // Light smoothing so the number doesn't twitch every second.
                    next.cpu = next.updatedAt == .distantPast ? reading.cpu : next.cpu * 0.4 + reading.cpu * 0.6
                    next.cpuHistory = Array((next.cpuHistory + [next.cpu]).suffix(60))
                    next.memoryUsed = reading.memoryUsed
                    next.downBytesPerSecond = reading.down
                    next.upBytesPerSecond = reading.up
                    next.temperature = reading.temperature
                    next.thermalState = ProcessInfo.processInfo.thermalState
                    next.updatedAt = Date()
                    service.snapshot = next
                }
            }
        }
    }
}

/// The actual measurements; runs on the stats queue and keeps the previous
/// counters to turn totals into rates.
private final class Sampler: @unchecked Sendable {
    struct Reading {
        var cpu: Double
        var memoryUsed: UInt64
        var down: Double
        var up: Double
        var temperature: Double?
    }

    private var lastTicks: [UInt64]?  // user, system, idle, nice totals
    private var lastNet: (down: UInt64, up: UInt64, time: TimeInterval)?
    private let temperatures = TemperatureSensors()

    func read() -> Reading {
        let net = netRates()
        return Reading(cpu: cpuUsage(), memoryUsed: memoryUsed(), down: net.0, up: net.1,
                       temperature: temperatures.averageCPU())
    }

    // MARK: CPU

    private func cpuUsage() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var totals = [UInt64](repeating: 0, count: 4)
        for cpu in 0..<Int(count) {
            let base = cpu * Int(CPU_STATE_MAX)
            totals[0] += UInt64(info[base + Int(CPU_STATE_USER)])
            totals[1] += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            totals[2] += UInt64(info[base + Int(CPU_STATE_IDLE)])
            totals[3] += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        defer { lastTicks = totals }
        guard let last = lastTicks else { return 0 }
        let d = zip(totals, last).map { $0 >= $1 ? Double($0 - $1) : 0 }
        let busy = d[0] + d[1] + d[3]
        let all = busy + d[2]
        return all > 0 ? busy / all : 0
    }

    // MARK: Memory

    /// What Activity Monitor calls "Memory Used": app + wired + compressed.
    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    // MARK: Network

    private var cachedRates: (Double, Double) = (0, 0)
    private var ratesStamp: TimeInterval = 0

    private func netRates() -> (Double, Double) {
        let now = Date().timeIntervalSince1970
        if now - ratesStamp < 0.5 { return cachedRates }
        ratesStamp = now
        var down: UInt64 = 0, up: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return cachedRates }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            let name = String(cString: ifa.pointee.ifa_name)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                down += UInt64(data.pointee.ifi_ibytes)
                up += UInt64(data.pointee.ifi_obytes)
            }
            ptr = ifa.pointee.ifa_next
        }
        defer { lastNet = (down, up, now) }
        guard let last = lastNet, now > last.time else { return (0, 0) }
        let dt = now - last.time
        // Counters are 32-bit per interface and wrap; ignore negative jumps.
        let d = down >= last.down ? Double(down - last.down) / dt : 0
        let u = up >= last.up ? Double(up - last.up) / dt : 0
        cachedRates = (d, u)
        return cachedRates
    }
}

/// Apple Silicon die temperatures through the IOHID event system — the
/// same sensors Stats reads. Resolved dynamically; if anything is missing
/// it simply reports nil and the panel shows the thermal state instead.
private final class TemperatureSensors {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValueFn = @convention(c) (AnyObject, UInt32) -> Double
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        handle.flatMap { dlsym($0, name) }.map { unsafeBitCast($0, to: T.self) }
    }
    private static let create = fn("IOHIDEventSystemClientCreate", CreateFn.self)
    private static let setMatching = fn("IOHIDEventSystemClientSetMatching", SetMatchingFn.self)
    private static let copyServices = fn("IOHIDEventSystemClientCopyServices", CopyServicesFn.self)
    private static let copyEvent = fn("IOHIDServiceClientCopyEvent", CopyEventFn.self)
    private static let floatValue = fn("IOHIDEventGetFloatValue", FloatValueFn.self)
    private static let copyProperty = fn("IOHIDServiceClientCopyProperty", CopyPropertyFn.self)

    private static let temperatureEvent: Int64 = 15               // kIOHIDEventTypeTemperature
    private static let temperatureField: UInt32 = 15 << 16        // IOHIDEventFieldBase(type)

    private var client: AnyObject?
    private var services: [AnyObject] = []

    init() {
        guard let create = Self.create, let setMatching = Self.setMatching, let copyServices = Self.copyServices,
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(client, matching as CFDictionary)
        self.client = client
        let all = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        // CPU die sensors ("PMU tdie…"); fall back to every sensor if the
        // names differ on this chip.
        let named = all.filter { service in
            let name = Self.copyProperty?(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            return name.contains("tdie") || name.contains("pACC") || name.contains("eACC")
        }
        services = named.isEmpty ? all : named
    }

    func averageCPU() -> Double? {
        guard let copyEvent = Self.copyEvent, let floatValue = Self.floatValue, !services.isEmpty else { return nil }
        var values: [Double] = []
        for service in services {
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let v = floatValue(event, Self.temperatureField)
            if v > 5 && v < 130 { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
