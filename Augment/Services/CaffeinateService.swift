import AppKit
import Combine
import IOKit.ps
import IOKit.pwr_mgt

/// Keep awake, Amphetamine-style: a manual session (optionally timed) plus
/// automatic triggers — while chosen apps run, while on power, while a
/// download is in progress. Options: let the display sleep anyway, and stay
/// awake with the lid closed.
@MainActor
final class CaffeinateService: ObservableObject {
    static let shared = CaffeinateService()

    /// A manual session is on (from the notch, quick panel or menu).
    @Published private(set) var isActive = false
    /// When a timed manual session ends; nil while off or indefinite.
    @Published private(set) var endDate: Date?
    /// The preset last chosen, in seconds (nil = indefinite).
    @Published private(set) var selectedPreset: Int?
    /// Why an automatic trigger is keeping the Mac awake, if one is.
    @Published private(set) var automaticReason: String?

    /// Durations offered in the notch / menu (nil = until turned off).
    static let presets: [TimeInterval?] = [15 * 60, 60 * 60, 2 * 60 * 60, 5 * 60 * 60, nil]

    private var assertions: [IOPMAssertionID] = []
    private var heldConfiguration: String?
    private var endTimer: Timer?
    private var ruleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let prefs = SharedPreferences.shared
        // Re-evaluate whenever a rule or option changes.
        Publishers.MergeMany(
            prefs.$awakeOnPower.map { _ in () }.eraseToAnyPublisher(),
            prefs.$awakeWhileDownloading.map { _ in () }.eraseToAnyPublisher(),
            prefs.$awakeWhileApps.map { _ in () }.eraseToAnyPublisher(),
            prefs.$awakeDisplayMaySleep.map { _ in () }.eraseToAnyPublisher(),
            prefs.$awakeLidClosed.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.evaluate() }
        .store(in: &cancellables)

        let t = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor in CaffeinateService.shared.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        ruleTimer = t
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
    }

    /// The Mac is being kept awake right now, for any reason.
    var isKeepingAwake: Bool { isActive || automaticReason != nil }

    // MARK: - Manual session

    func toggle() {
        isActive ? deactivate() : activate()
    }

    func activate() {
        activate(for: nil)
    }

    /// Keeps the Mac awake for `duration` seconds, or until turned off.
    func activate(for duration: TimeInterval?) {
        isActive = true
        selectedPreset = duration.map { Int($0) }
        endTimer?.invalidate()
        endTimer = nil
        if let duration {
            let end = Date().addingTimeInterval(duration)
            endDate = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { _ in
                Task { @MainActor in CaffeinateService.shared.deactivate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            endTimer = timer
        } else {
            endDate = nil
        }
        evaluate()
    }

    func deactivate() {
        endTimer?.invalidate()
        endTimer = nil
        endDate = nil
        selectedPreset = nil
        isActive = false
        evaluate()
    }

    // MARK: - Rules

    func evaluate() {
        automaticReason = currentAutomaticReason()
        let prefs = SharedPreferences.shared
        let wanted: String? = isKeepingAwake
            ? "display:\(!prefs.awakeDisplayMaySleep) lid:\(prefs.awakeLidClosed)"
            : nil
        guard wanted != heldConfiguration else { return }
        releaseAssertions()
        if wanted != nil { createAssertions(displayMaySleep: prefs.awakeDisplayMaySleep, lidClosed: prefs.awakeLidClosed) }
        heldConfiguration = wanted
    }

    private func currentAutomaticReason() -> String? {
        let prefs = SharedPreferences.shared
        if !prefs.awakeWhileApps.isEmpty {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            if let hit = prefs.awakeWhileApps.first(where: running.contains) {
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hit)
                    .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? hit
                return String(format: Localizer.string("awake.reason_app"), name)
            }
        }
        if prefs.awakeOnPower && Self.isOnACPower() {
            return Localizer.string("awake.reason_power")
        }
        if prefs.awakeWhileDownloading && Self.isDownloading() {
            return Localizer.string("awake.reason_download")
        }
        return nil
    }

    static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPSACPowerValue
    }

    /// Browsers write in-progress downloads with these extensions.
    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload", "tmp"]

    static func isDownloading() -> Bool {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)
        else { return false }
        return items.contains { partialExtensions.contains($0.pathExtension.lowercased()) }
    }

    // MARK: - Power assertions

    private func createAssertions(displayMaySleep: Bool, lidClosed: Bool) {
        let reason = "Augment: keep awake" as CFString
        var types: [String] = [kIOPMAssertionTypePreventUserIdleSystemSleep]
        if !displayMaySleep { types.append(kIOPMAssertionTypeNoDisplaySleep) }
        // Prevents sleep even with the lid closed — macOS honours this only
        // while the Mac is on power (anything more needs root).
        if lidClosed { types.append(kIOPMAssertionTypePreventSystemSleep) }
        for type in types {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess {
                assertions.append(id)
            } else {
                NSLog("Augment: CaffeinateService – failed to create %@ assertion", type)
            }
        }
    }

    private func releaseAssertions() {
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
    }
}
