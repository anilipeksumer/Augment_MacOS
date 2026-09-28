import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// "Cut & paste" window placement, modeled on the Windows 11 24H2 feature of
/// the same name: mark the focused window with ⌃⌘X, then move the mouse
/// anywhere (any screen) and press ⌃⌘V to relocate the window there,
/// preserving its relative position/size on the new screen.
///
/// Deliberately bound to ⌃⌘ (Control+Command) rather than the bare ⌘X/⌘V the
/// user asked to mimic — those are the system-wide text/file cut & paste
/// shortcut on every app on macOS, so reusing them globally would hijack
/// ordinary copy/paste everywhere. ⌃⌘X/V doesn't collide with anything by
/// default and is not remapped elsewhere in the app.
@MainActor
final class WindowCutPasteService {

    private(set) var isRunning = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var cutWindow: AXUIElement?
    private var cutOriginFrame: CGRect?
    private var cutOriginScreen: NSScreen?

    private static let cutKeyCode: UInt16 = 7   // 'x'
    private static let pasteKeyCode: UInt16 = 9 // 'v'
    private static let requiredFlags: CGEventFlags = [.maskCommand, .maskControl]

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
        cutWindow = nil
        cutOriginFrame = nil
        cutOriginScreen = nil
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
                let service = Unmanaged<WindowCutPasteService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Augment: WindowCutPasteService – failed to create event tap (Accessibility?)")
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
        guard flags == Self.requiredFlags else { return Unmanaged.passUnretained(event) }

        if keyCode == Self.cutKeyCode {
            DispatchQueue.main.async { [weak self] in self?.cutFocusedWindow() }
            return nil
        }
        if keyCode == Self.pasteKeyCode {
            DispatchQueue.main.async { [weak self] in self?.pasteWindowAtCursor() }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Cut / paste

    private func cutFocusedWindow() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &focusedValue
        ) == .success, let window = AXElementCoercion.element(focusedValue) else { return }

        guard let frame = axFrame(of: window),
              let screen = bestScreen(for: frame) else { return }

        cutWindow = window
        cutOriginFrame = frame
        cutOriginScreen = screen
        NSSound(named: "Pop")?.play()
    }

    private func pasteWindowAtCursor() {
        guard let window = cutWindow,
              let originFrame = cutOriginFrame,
              let originScreen = cutOriginScreen else { return }
        cutWindow = nil
        cutOriginFrame = nil
        cutOriginScreen = nil

        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = ScreenGeometry.screen(containing: mouseLocation) else { return }

        let targetFrame: CGRect
        if targetScreen == originScreen {
            targetFrame = originFrame
        } else {
            // Preserve the window's relative position/size within its
            // origin screen's visible area, mapped onto the target screen —
            // same effect as dragging a window between differently-sized
            // monitors, without needing to actually drag it.
            let originVisible = originScreen.visibleFrame
            let targetVisible = targetScreen.visibleFrame
            let relX = originVisible.width > 0 ? (originFrame.minX - originVisible.minX) / originVisible.width : 0
            let relY = originVisible.height > 0 ? (originFrame.minY - originVisible.minY) / originVisible.height : 0
            let relW = originVisible.width > 0 ? originFrame.width / originVisible.width : 1
            let relH = originVisible.height > 0 ? originFrame.height / originVisible.height : 1

            targetFrame = CGRect(
                x: targetVisible.minX + relX * targetVisible.width,
                y: targetVisible.minY + relY * targetVisible.height,
                width: relW * targetVisible.width,
                height: relH * targetVisible.height
            )
        }

        setAXFrame(window, to: targetFrame)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        NSSound(named: "Pop")?.play()
    }

    // MARK: - AX frame helpers (top-left CG <-> bottom-left AppKit)

    private func axFrame(of window: AXUIElement) -> CGRect? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXPositionAttribute as CFString, &posValue
        ) == .success,
              AXUIElementCopyAttributeValue(
                window, kAXSizeAttribute as CFString, &sizeValue
              ) == .success else { return nil }

        guard let point = AXElementCoercion.point(from: posValue),
              let size = AXElementCoercion.size(from: sizeValue) else { return nil }

        let appKitPoint = ScreenGeometry.convertFromCG(point)
        return CGRect(
            x: appKitPoint.x,
            y: appKitPoint.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func setAXFrame(_ window: AXUIElement, to frame: CGRect) {
        var position = ScreenGeometry.convertToCG(CGPoint(x: frame.minX, y: frame.maxY))
        var size = CGSize(width: frame.width, height: frame.height)

        if let posVal = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        var bestOverlap: CGFloat = 0
        var bestScreen: NSScreen?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(frame)
            let area = overlap.width * overlap.height
            if area > bestOverlap {
                bestOverlap = area
                bestScreen = screen
            }
        }
        return bestScreen ?? NSScreen.main
    }
}
