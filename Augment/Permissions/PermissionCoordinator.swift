import AppKit
import ApplicationServices
import Combine
import Foundation

/// Trust state of the Augment process with respect to the macOS Accessibility API.
public enum AccessibilityTrustState: Equatable {
    /// Trust hasn't been queried yet during this session.
    case unknown
    /// The user has not granted Accessibility access to Augment.
    case denied
    /// The user has granted Accessibility access; AX/CGEvent APIs may be used.
    case granted
}

/// Coordinates the macOS Accessibility permission lifecycle.
///
/// macOS doesn't deliver an event when a user grants Accessibility access in
/// System Settings, so the coordinator polls `AXIsProcessTrusted()` while the
/// app is in the "denied" state. The polling interval uses an exponential
/// back-off bounded between 0.5s and 5s so we react quickly when permission
/// is first granted but we never burn CPU long-term.
@MainActor
public final class PermissionCoordinator: ObservableObject {
    /// Current Accessibility trust state, observable from SwiftUI.
    @Published public private(set) var state: AccessibilityTrustState = .unknown

    /// Increments every time the coordinator detects a trust transition.
    /// Useful for triggering UI feedback in tests.
    @Published public private(set) var transitionCount: Int = 0

    /// True if the coordinator is actively polling for permission changes.
    @Published public private(set) var isPolling: Bool = false

    private var pollingTask: Task<Void, Never>?
    private var currentDelay: UInt64 = 500_000_000  // 0.5s in nanoseconds
    private let maxDelay: UInt64 = 5_000_000_000    // 5s in nanoseconds
    private let preferences: SharedPreferences

    public init(preferences: SharedPreferences = .shared) {
        self.preferences = preferences
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - Public API

    /// Reads `AXIsProcessTrusted()` once and updates `state` accordingly.
    /// This call does **not** prompt the user.
    public func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            preferences.syncAccessibilityPromptFlagIfProcessTrusted()
        }
        update(state: trusted ? .granted : .denied)
    }

    /// Updates trust state and starts polling when needed.
    ///
    /// **Automatic flows** (`force: false`) never call `AXIsProcessTrustedWithOptions` with
    /// `kAXTrustedCheckOptionPrompt` — macOS may still show that sheet unpredictably when
    /// persistence/TCC state is messy; onboarding + Settings handle guidance instead.
    ///
    /// **`force: true`** (Settings → “Re-prompt”) asks the system to show the official
    /// Accessibility prompt once for explicit retries.
    public func requestAccessAndBeginPolling(force: Bool = false) {
        // Always check current trust first – the user may have granted us
        // access in System Settings between launches.
        let alreadyTrusted = AXIsProcessTrusted()
        if alreadyTrusted {
            preferences.syncAccessibilityPromptFlagIfProcessTrusted()
            update(state: .granted)
            return
        }

        if force {
            preferences.hasRequestedAccessibilityPrompt = true
            SharedPreferences.synchronizeAppGroup()
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options: CFDictionary = [promptKey: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            update(state: trusted ? .granted : .denied)
            if !trusted {
                startPolling()
            }
            return
        }

        if !preferences.hasRequestedAccessibilityPrompt {
            preferences.hasRequestedAccessibilityPrompt = true
            SharedPreferences.synchronizeAppGroup()
            update(state: .denied)
            startPolling()
            return
        }

        update(state: .denied)
        startPolling()
    }

    /// Stops the polling loop (called when the app is shutting down or the
    /// permission window closes after a successful grant).
    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        currentDelay = 500_000_000
        isPolling = false
    }

    /// Opens the Accessibility pane of System Settings so the user can grant
    /// access without having to drill through the Settings UI manually.
    public func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Internals

    private func startPolling() {
        guard pollingTask == nil else { return }
        isPolling = true
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.currentDelay
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                let trusted = AXIsProcessTrusted()
                if trusted {
                    self.update(state: .granted)
                    self.stopPolling()
                    return
                }
                // Exponential back-off, capped, to avoid burning CPU while
                // still being quick to react when the user flips the switch.
                self.currentDelay = min(self.currentDelay * 2, self.maxDelay)
            }
        }
    }

    private func update(state newState: AccessibilityTrustState) {
        guard newState != state else { return }
        state = newState
        transitionCount += 1
    }
}
