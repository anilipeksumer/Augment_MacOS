import AppKit
import Carbon
import SwiftUI

// MARK: - Window controller

/// Standalone AppKit window that hosts the Augment settings UI.
///
/// `LSUIElement` apps make the SwiftUI `Settings` scene unreliable – the
/// auto-generated `showSettingsWindow:` action quietly does nothing if no
/// app window is currently key. Owning the window directly side-steps the
/// entire responder-chain dance and lets us guarantee the window comes up
/// every time the user picks "Settings…" from the menu bar.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    init(preferences: SharedPreferences, permissionCoordinator: PermissionCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Augment Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // Avoid `.preference`: pairing it with SwiftUI's `TabView` on recent
        // macOS releases can inject a navigation-style toolbar with a `>>`
        // sidebar toggle. We render our own tab strip instead of `TabView`,
        // so the default window chrome stays minimal.
        window.center()
        window.setFrameAutosaveName("AugmentSettingsWindow")
        window.identifier = NSUserInterfaceItemIdentifier("AugmentSettingsWindow")

        let root = SettingsRootView()
            .environmentObject(preferences)
            .environmentObject(permissionCoordinator)

        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Reset both the selected tab and the General drill-down path
        // every time the window is brought forward, so re-opening Settings
        // always lands the user on the home view rather than wherever
        // they last were. The notification is observed by SettingsRootView
        // and the General pane.
        NotificationCenter.default.post(
            name: SettingsRootView.shouldResetNotification,
            object: nil
        )
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        if !window.isVisible {
            window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        let hasOtherWindows = NSApp.windows.contains { w in
            w.isVisible && w != notification.object as? NSWindow && w.className != "NSStatusBarWindow"
        }
        if !hasOtherWindows {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - SwiftUI root

struct SettingsRootView: View {
    @EnvironmentObject private var preferences: SharedPreferences
    @EnvironmentObject private var permissions: PermissionCoordinator

    /// Notification posted by `SettingsWindowController.show()` to bring
    /// the UI back to its home view (General tab, no drill-down). The
    /// root view and the General pane both listen for it.
    static let shouldResetNotification = Notification.Name(
        "augment.settings.shouldReset"
    )

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedTab)
                .frame(width: 200)
            Divider()
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsPane()
                case .hover:
                    HoverSettingsPane()
                case .windowControls:
                    WindowControlsSettingsPane()
                case .dockClick:
                    DockClickSettingsPane()
                case .displays:
                    DisplaySettingsPane()
                case .finder:
                    FinderSettingsPane()
                case .windowSnapping:
                    WindowSnappingSettingsPane()
                case .notch:
                    NotchSettingsPane()
                case .permissions:
                    PermissionsSettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 720, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: Self.shouldResetNotification)) { _ in
            selectedTab = .general
        }
        .onAppear {
            updateWindowTitle()
        }
        .onChange(of: preferences.appLanguage) { _ in
            updateWindowTitle()
        }
    }

    private func updateWindowTitle() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "AugmentSettingsWindow" }) {
            window.title = Localizer.string("settings.title")
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer()
            Divider().padding(.horizontal, 12)
            aboutRow
                .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = selection == tab
        let isHovered = hoveredTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selection = tab
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(tab.tintColor)
                    )
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? tab : nil }
    }

    private var aboutRow: some View {
        Button {
            NotificationCenter.default.post(name: Notification.Name("augment.showAbout"), object: nil)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.gray)
                    )
                Text(Localizer.string("menu.about"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, hover, windowControls, dockClick, displays, finder, windowSnapping, notch, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return Localizer.string("tab.general")
        case .hover: return Localizer.string("tab.hover")
        case .windowControls: return Localizer.string("tab.windowControls")
        case .dockClick: return Localizer.string("tab.dockClick")
        case .displays: return Localizer.string("tab.displays")
        case .finder: return Localizer.string("tab.finder")
        case .windowSnapping: return Localizer.string("tab.windowSnapping")
        case .notch: return Localizer.string("tab.notch")
        case .permissions: return Localizer.string("tab.permissions")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .hover: return "rectangle.stack.badge.play"
        case .windowControls: return "macwindow.on.rectangle"
        case .dockClick: return "cursorarrow.click.2"
        case .displays: return "display.2"
        case .finder: return "folder.fill.badge.plus"
        case .windowSnapping: return "rectangle.split.2x1.fill"
        case .notch: return "platter.filled.top.iphone"
        case .permissions: return "lock.shield.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .general: return .accentColor
        case .hover: return .blue
        case .windowControls: return .green
        case .dockClick: return .indigo
        case .displays: return .pink
        case .finder: return .green
        case .windowSnapping: return .cyan
        case .notch: return .purple
        case .permissions: return .orange
        }
    }
}

// MARK: - Reusable building blocks

struct PaneHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    @State private var iconBounce = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(
                        colors: [tint.opacity(0.85), tint.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 52, height: 52)
                    .shadow(color: tint.opacity(0.35), radius: 6, y: 2)

                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(iconBounce ? 1.06 : 1.0)
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.55).repeatCount(3, autoreverses: true),
                        value: iconBounce
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 6)
        .onAppear { iconBounce = true }
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tint)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Identifier for a sub-pane reachable from the General drill-down list.
///
/// Drives a plain `@State` selection in the General pane: when set, the
/// pane shows the corresponding detail view; when `nil`, the home Form
/// renders. We deliberately avoid `NavigationStack` / `NavigationPath`
/// because macOS attaches a navigation toolbar to every stack — that
/// toolbar shows up as a `>>` chevron in the title bar, which the user
/// repeatedly asked us to remove.
enum FeatureDestination: Hashable {
    case hover
    case dockClick
    case windowControls
    case folderQuickLook
    case finderMenu
    case displays
    case windowSnapping
    case notch

    var title: String {
        switch self {
        case .hover: return "Hover"
        case .dockClick: return "Dock Click"
        case .windowControls: return "Window Controls"
        case .folderQuickLook: return "Folder Quick Look"
        case .finderMenu: return "Finder Menu"
        case .displays: return "Displays"
        case .windowSnapping: return "Window Snapping"
        case .notch: return "Notch"
        }
    }
}

/// Row used inside the General pane's drill-down list.
///
/// Tapping the icon-and-text area pushes the matching `FeatureDestination`
/// onto the parent's `NavigationPath`. The trailing toggle still flips
/// the preference without navigating, so users can enable / disable a
/// feature without leaving the General view.
struct FeatureNavRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onSelect) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(tint)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Wraps a detail pane in a slim header row with a back chevron + label
/// that returns to the General root. We render this manually rather than
/// relying on a `NavigationStack` toolbar because macOS adds a chevron
/// indicator to that toolbar that we don't want, and there's no public
/// API to hide it on Form-style content.
struct DetailContainer<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 12, weight: .semibold))
                        Text("General")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            content()
        }
    }
}

