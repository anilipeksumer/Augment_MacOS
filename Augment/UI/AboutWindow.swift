import AppKit
import SwiftUI

enum AugmentApplicationIcon {
    static func load(bundle: Bundle = .main) -> NSImage? {
        guard let url = bundle.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AboutWindowController?

    static func showAbout() {
        if shared == nil {
            shared = AboutWindowController()
        }
        shared?.show()
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = Localizer.string("menu.about")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.center()

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: AboutView { [weak window] in
            window?.performClose(nil)
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
        let hasOtherWindows = NSApp.windows.contains { w in
            w.isVisible && w != notification.object as? NSWindow && w.className != "NSStatusBarWindow"
        }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct AboutView: View {
    let onClose: () -> Void
    @ObservedObject private var preferences = SharedPreferences.shared

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                appIcon
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)

                VStack(spacing: 4) {
                    Text("Augment")
                        .font(.system(size: 28, weight: .bold))
                    Text(Localizer.string("about.description"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Text("\(Localizer.string("about.version")) \(version) (\(build))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 30)
            .padding(.bottom, 24)

            Divider()

            HStack(spacing: 0) {
                CapabilityCard(title: Localizer.string("about.dock_previews"), icon: "rectangle.stack.fill")
                Divider().frame(height: 46)
                CapabilityCard(title: Localizer.string("about.finder_tools"), icon: "folder.fill.badge.plus")
                Divider().frame(height: 46)
                CapabilityCard(title: Localizer.string("about.interactive_notch"), icon: "platter.filled.top.iphone")
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 18)

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Anıl İpeksümer")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Copyright © \(String(Calendar.current.component(.year, from: Date())))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(Localizer.string("about.close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
        }
        .frame(width: 460, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var appIcon: some View {
        if let image = AugmentApplicationIcon.load() ?? NSApp.applicationIconImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor)
        }
    }
}

struct CapabilityCard: View {
    let title: String
    let icon: String
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .scaleEffect(isHovered ? 1.12 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.55), value: isHovered)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isHovered ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
