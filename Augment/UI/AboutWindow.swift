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
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Localizer.string("menu.about")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
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

/// A compact About panel in the spirit of macOS's own: icon, name,
/// version, one line on what Augment is, what it covers, and the credits.
struct AboutView: View {
    let onClose: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    private let areas: [SettingsTab] = [.dock, .windows, .finder, .notch, .sound]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 34)
            appIcon
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)

            Text("Augment")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 14)
            Text("\(Localizer.string("about.version")) \(version) (\(build))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .textSelection(.enabled)

            Text(Localizer.string("about.description"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)
                .padding(.top, 14)

            HStack(spacing: 14) {
                ForEach(areas, id: \.self) { tab in
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tab.tintColor.gradient))
                        .help(tab.title)
                }
            }
            .padding(.top, 18)

            Spacer(minLength: 20)

            Text("© \(String(Calendar.current.component(.year, from: Date()))) Anıl İpeksümer")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(width: 340, height: 400)
        .background(.regularMaterial)
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
        }
    }
}
