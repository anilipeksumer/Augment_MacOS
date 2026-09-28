import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import SwiftUI

/// A snap target the picker can place the frontmost window into.
enum SnapZone: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case leftThird, centerThird, rightThird

    var id: String { rawValue }

    /// Fraction of the screen's visible frame this zone occupies, expressed
    /// with AppKit's bottom-left origin (matches `NSScreen.visibleFrame`).
    var unitRect: CGRect {
        switch self {
        case .leftHalf:           return CGRect(x: 0,   y: 0, width: 0.5, height: 1)
        case .rightHalf:          return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topLeftQuarter:     return CGRect(x: 0,   y: 0.5, width: 0.5, height: 0.5)
        case .topRightQuarter:    return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .bottomLeftQuarter:  return CGRect(x: 0,   y: 0,   width: 0.5, height: 0.5)
        case .bottomRightQuarter: return CGRect(x: 0.5, y: 0,   width: 0.5, height: 0.5)
        case .leftThird:          return CGRect(x: 0,       y: 0, width: 1.0 / 3, height: 1)
        case .centerThird:        return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird:         return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        }
    }

    func frame(in visibleFrame: CGRect) -> CGRect {
        let u = unitRect
        return CGRect(
            x: visibleFrame.minX + u.minX * visibleFrame.width,
            y: visibleFrame.minY + u.minY * visibleFrame.height,
            width: u.width * visibleFrame.width,
            height: u.height * visibleFrame.height
        )
    }
}

/// Windows 11 "Snap Layouts"-style flyout: a hotkey shows a small grid of
/// window arrangements near the cursor; clicking one snaps the frontmost
/// window into that zone via Accessibility, mirroring `WindowSnappingService`'s
/// AX frame manipulation but for a richer set of zones than plain halves.
@MainActor
final class SnapLayoutsService {
    private(set) var isRunning = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var panel: NSPanel?

    /// Default: ⌃⌥Space. Chosen because it's not a standard macOS shortcut.
    private static let triggerKeyCode: UInt16 = 49 // Space
    private static let triggerFlags: CGEventFlags = [.maskControl, .maskAlternate]

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
        dismissPanel()
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
                let service = Unmanaged<SnapLayoutsService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Augment: SnapLayoutsService – failed to create event tap (Accessibility?)")
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

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])

        if keyCode == 53 && panel != nil { // Escape closes the picker
            DispatchQueue.main.async { [weak self] in self?.dismissPanel() }
            return nil
        }

        guard keyCode == Self.triggerKeyCode, flags == Self.triggerFlags else {
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async { [weak self] in self?.togglePanel() }
        return nil
    }

    // MARK: - Panel

    private func togglePanel() {
        if panel != nil {
            dismissPanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        ) == .success, let window = AXElementCoercion.element(focusedValue) else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = ScreenGeometry.screen(containing: mouseLocation) ?? NSScreen.main

        let panelSize = CGSize(width: 260, height: 150)
        var origin = CGPoint(x: mouseLocation.x - panelSize.width / 2, y: mouseLocation.y - panelSize.height - 12)
        if let screen {
            origin.x = min(max(origin.x, screen.frame.minX + 8), screen.frame.maxX - panelSize.width - 8)
            origin.y = max(origin.y, screen.frame.minY + 8)
        }

        let hostingView = NSHostingView(rootView: SnapLayoutsPickerView(
            onSelect: { [weak self] zone in
                self?.applyZone(zone, to: window, screen: screen)
                self?.dismissPanel()
            }
        ))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: panelSize)

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = hostingView
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.orderFrontRegardless()
        panel = p
    }

    private func dismissPanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func applyZone(_ zone: SnapZone, to window: AXUIElement, screen: NSScreen?) {
        guard let screen else { return }
        let targetFrame = zone.frame(in: screen.visibleFrame)
        var position = ScreenGeometry.convertToCG(CGPoint(x: targetFrame.minX, y: targetFrame.maxY))
        var size = CGSize(width: targetFrame.width, height: targetFrame.height)
        if let posVal = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }
}

/// The flyout grid itself: two halves on top, four quarters below.
private struct SnapLayoutsPickerView: View {
    let onSelect: (SnapZone) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                zoneButton(.leftHalf)
                zoneButton(.rightHalf)
            }
            HStack(spacing: 8) {
                zoneButton(.topLeftQuarter)
                zoneButton(.topRightQuarter)
                zoneButton(.bottomLeftQuarter)
                zoneButton(.bottomRightQuarter)
            }
            HStack(spacing: 8) {
                zoneButton(.leftThird)
                zoneButton(.centerThird)
                zoneButton(.rightThird)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        )
    }

    private func zoneButton(_ zone: SnapZone) -> some View {
        Button {
            onSelect(zone)
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .overlay(zonePreview(zone))
                .frame(width: 36, height: 26)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func zonePreview(_ zone: SnapZone) -> some View {
        GeometryReader { geo in
            let u = zone.unitRect
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: u.width * geo.size.width, height: u.height * geo.size.height)
                .position(
                    x: (u.minX + u.width / 2) * geo.size.width,
                    y: (1 - u.minY - u.height / 2) * geo.size.height
                )
        }
    }
}
