import AppKit
import SwiftUI

/// SwiftUI overlay that captures middle-click and right-click events the
/// vanilla SwiftUI gesture system doesn't surface.
///
/// Uses a transparent `NSView` host so the underlying SwiftUI gestures
/// (tap, hover) remain functional. Events that aren't the configured
/// middle-click are forwarded down the responder chain unchanged.
struct MouseEventCatcher: NSViewRepresentable {
    var onMiddleClick: () -> Void
    var onScrollClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        let view = ButtonForwardingView()
        view.onMiddleClick = onMiddleClick
        view.onScrollClose = onScrollClose
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? ButtonForwardingView else { return }
        v.onMiddleClick = onMiddleClick
        v.onScrollClose = onScrollClose
    }

    private final class ButtonForwardingView: NSView {
        var onMiddleClick: (() -> Void)?
        var onScrollClose: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only intercept for events we actually care about; otherwise
            // pass through to the underlying SwiftUI cell so taps/drags
            // continue to work.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .otherMouseDown, .scrollWheel:
                return self
            default:
                return nil
            }
        }

        override func otherMouseDown(with event: NSEvent) {
            // Cocoa labels the wheel button as buttonNumber == 2.
            if event.buttonNumber == 2 {
                onMiddleClick?()
            } else {
                super.otherMouseDown(with: event)
            }
        }

        override func scrollWheel(with event: NSEvent) {
            // Tactile shortcut for users without a middle button: a strong
            // click + downward scroll behaves like the middle-button close
            // gesture. Threshold tuned to avoid firing during gentle pan
            // gestures.
            guard let onScrollClose else {
                super.scrollWheel(with: event)
                return
            }
            if abs(event.deltaY) > 6 || abs(event.scrollingDeltaY) > 24 {
                onScrollClose()
            }
        }
    }
}
