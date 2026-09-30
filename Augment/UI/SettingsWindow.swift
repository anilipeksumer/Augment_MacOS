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
        window.title = Localizer.string("settings.title")
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

    /// Posted with a `SettingsTab.rawValue` object to jump to a page.
    static let selectTabNotification = Notification.Name("augment.settings.selectTab")

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selectedTab)
                .frame(width: 200)
            Divider()
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsPane(open: { tab in selectedTab = tab })
                case .dock:
                    DockPage()
                case .windows:
                    WindowsPage()
                case .finder:
                    FinderPage()
                case .notch:
                    NotchPage()
                case .sound:
                    SoundDisplayPage()
                case .awake:
                    AwakePage()
                case .menuBar:
                    MenuBarPage()
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
        .onReceive(NotificationCenter.default.publisher(for: Self.selectTabNotification)) { note in
            if let raw = note.object as? String, let tab = SettingsTab(rawValue: raw) { selectedTab = tab }
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

/// The eight Settings pages, in sidebar order.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, dock, windows, finder, notch, sound, awake, menuBar, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return Localizer.string("tab.general")
        case .dock: return Localizer.string("page.dock")
        case .windows: return Localizer.string("page.windows")
        case .finder: return Localizer.string("page.finder")
        case .notch: return Localizer.string("tab.notch")
        case .sound: return Localizer.string("page.sound")
        case .awake: return Localizer.string("page.awake_title")
        case .menuBar: return Localizer.string("page.menubar")
        case .permissions: return Localizer.string("tab.permissions")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .dock: return "dock.rectangle"
        case .windows: return "macwindow.on.rectangle"
        case .finder: return "folder.fill"
        case .notch: return "platter.filled.top.iphone"
        case .sound: return "speaker.wave.2.fill"
        case .awake: return "cup.and.saucer.fill"
        case .menuBar: return "menubar.rectangle"
        case .permissions: return "lock.shield.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .general: return .gray
        case .dock: return .blue
        case .windows: return .cyan
        case .finder: return .green
        case .notch: return .purple
        case .sound: return .red
        case .awake: return .orange
        case .menuBar: return .indigo
        case .permissions: return .orange
        }
    }
}

// MARK: - Reusable building blocks

/// Page header in the style of System Settings: a tinted app-style tile,
/// the page name and one line on what the page controls.
struct PaneHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.gradient)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool
    /// Permissions this feature needs. While the feature is on and any of
    /// them is missing, an inline notice with a Grant button is shown.
    var requires: [FeaturePermission] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggle
            if isOn && !requires.isEmpty {
                PermissionNotice(permissions: requires)
                    .padding(.leading, 42)
            }
        }
    }

    /// Plain title/subtitle row like System Settings; colour is reserved for
    /// the sidebar so pages stay calm.
    private var toggle: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Lists a feature's missing permissions with a button to grant each one.
/// Re-checks every couple of seconds so it disappears once the user flips
/// the switch in System Settings.
struct PermissionNotice: View {
    let permissions: [FeaturePermission]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let missing = permissions.filter { !$0.isGranted }
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(missing, id: \.self) { permission in
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(String(format: Localizer.string("perm.needed"), permission.title))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(Localizer.string("perm.grant")) { permission.request() }
                                .controlSize(.small)
                        }
                    }
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

