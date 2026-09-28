import AppKit
import SwiftUI

/// A short tour shown on first launch (and from the menu): what Augment
/// does and where to find it, ending in Settings where features are
/// switched on.
@MainActor
final class WelcomeTourController: NSWindowController, NSWindowDelegate {
    private static var shared: WelcomeTourController?
    static let didShowKey = "augment.didShowWelcomeTour"

    static var hasShown: Bool { UserDefaults.standard.bool(forKey: didShowKey) }

    static func show(onFinish: @escaping () -> Void) {
        if shared == nil { shared = WelcomeTourController(onFinish: onFinish) }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.center()
        shared?.window?.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: didShowKey)
    }

    private init(onFinish: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeTourView { [weak window] in
            window?.close()
            onFinish()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        if !NSApp.windows.contains(where: { $0.isVisible && $0 != window && $0.className != "NSStatusBarWindow" }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

private struct TourPage {
    let icon: String
    let tint: Color
    let titleKey: String
    let bodyKey: String
}

struct WelcomeTourView: View {
    let onFinish: () -> Void
    @State var index = 0

    private let pages: [TourPage] = [
        TourPage(icon: "sparkles", tint: .blue, titleKey: "tour.welcome_title", bodyKey: "tour.welcome_body"),
        TourPage(icon: "menubar.rectangle", tint: .indigo, titleKey: "tour.panel_title", bodyKey: "tour.panel_body"),
        TourPage(icon: "platter.filled.top.iphone", tint: .purple, titleKey: "tour.notch_title", bodyKey: "tour.notch_body"),
        TourPage(icon: "macwindow.on.rectangle", tint: .cyan, titleKey: "tour.windows_title", bodyKey: "tour.windows_body"),
        TourPage(icon: "folder.fill", tint: .green, titleKey: "tour.finder_title", bodyKey: "tour.finder_body"),
        TourPage(icon: "checkmark.seal.fill", tint: .orange, titleKey: "tour.ready_title", bodyKey: "tour.ready_body"),
    ]

    var body: some View {
        let page = pages[index]
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            Group {
                if index == 0, let icon = AugmentApplicationIcon.load() ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                } else {
                    Image(systemName: page.icon)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 88)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(page.tint.gradient))
                        .shadow(color: page.tint.opacity(0.35), radius: 12, y: 6)
                }
            }
            .id(index)
            .transition(.scale(scale: 0.9).combined(with: .opacity))

            Text(Localizer.string(page.titleKey))
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 22)
            Text(Localizer.string(page.bodyKey))
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 10)
                .id("body\(index)")
                .transition(.opacity)

            if index == 4 && !FinderExtensionStatus.isEnabled {
                Button(Localizer.string("finderext.enable")) { FinderExtensionStatus.openSettings() }
                    .padding(.top, 12)
            }

            Spacer(minLength: 20)

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: i == index ? 18 : 7, height: 7)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: index)
            .padding(.bottom, 18)

            HStack {
                if index > 0 {
                    Button(Localizer.string("tour.back")) { go(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                } else {
                    Button(Localizer.string("tour.skip")) { onFinish() }
                }
                Spacer()
                Button(Localizer.string(index == pages.count - 1 ? "tour.open_settings" : "tour.next")) {
                    index == pages.count - 1 ? onFinish() : go(1)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(width: 560, height: 440)
        .background(.regularMaterial)
    }

    private func go(_ delta: Int) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            index = min(max(index + delta, 0), pages.count - 1)
        }
    }
}
