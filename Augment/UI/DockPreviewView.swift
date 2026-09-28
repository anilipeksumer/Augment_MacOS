import AppKit
import Combine
import SwiftUI

/// View-model backing the Dock preview panel.
///
/// Holds the in-flight window snapshots, the resolved app display name, and
/// the user-configurable presentation knobs (panel size, close button
/// visibility, traffic-light controls, drag/middle-click toggles) that the
/// controller forwards from `SharedPreferences`. The action closures are
/// wired by the `AppDelegate` and let individual thumbnail cells trigger
/// window-management actions.
@MainActor
final class DockPreviewViewModel: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    var snapshots: [WindowSnapshot] = []
    var displayName: String = ""
    var bundleID: String = ""
    var appIcon: NSImage?

    var panelSize: PreviewPanelSize = .standard
    var showCloseButton = true
    var trafficLightEnabled = true
    var trafficLightSide: TrafficLightSide = .trailing
    var killButtonVisible = false
    var middleClickEnabled = true
    var dragOutEnabled = true
    var headerActionsEnabled = true
    var isMagnified = false {
        didSet {
            if oldValue != isMagnified {
                objectWillChange.send()
            }
        }
    }

    /// Invoked when the user clicks the body of a thumbnail cell.
    var onActivate: ((WindowSnapshot) -> Void)?
    /// Invoked when the user clicks the close glyph on a thumbnail cell.
    var onClose: ((WindowSnapshot) -> Void)?
    /// Invoked when the user middle-clicks a thumbnail cell.
    var onMinimize: ((WindowSnapshot) -> Void)?
    var onZoom: ((WindowSnapshot) -> Void)?
    var onKill: ((WindowSnapshot) -> Void)?
    var onDragOut: ((WindowSnapshot) -> Void)?

    /// Header actions (apply to every window of the hovered app).
    var onCloseAll: (() -> Void)?
    var onMinimizeAll: (() -> Void)?

    func update(snapshots: [WindowSnapshot], displayName: String, bundleID: String, appIcon: NSImage?) {
        objectWillChange.send()
        self.snapshots = snapshots
        self.displayName = displayName
        self.bundleID = bundleID
        self.appIcon = appIcon
    }

    func updateAppearance(
        panelSize: PreviewPanelSize,
        showCloseButton: Bool,
        trafficLightEnabled: Bool,
        trafficLightSide: TrafficLightSide,
        killButtonVisible: Bool,
        middleClickEnabled: Bool,
        dragOutEnabled: Bool,
        headerActionsEnabled: Bool
    ) {
        objectWillChange.send()
        self.panelSize = panelSize
        self.showCloseButton = showCloseButton
        self.trafficLightEnabled = trafficLightEnabled
        self.trafficLightSide = trafficLightSide
        self.killButtonVisible = killButtonVisible
        self.middleClickEnabled = middleClickEnabled
        self.dragOutEnabled = dragOutEnabled
        self.headerActionsEnabled = headerActionsEnabled
    }

    func removeSnapshot(id: CGWindowID) -> Bool {
        let remaining = snapshots.filter { $0.id != id }
        guard remaining.count != snapshots.count else { return false }
        objectWillChange.send()
        snapshots = remaining
        return true
    }
}

/// SwiftUI body of the Dock preview panel.
///
/// The visual style follows Apple's HUD/popover language: vibrant
/// `NSVisualEffectView` background, hairline border, generous padding,
/// rounded corners, and SF symbol/text fallback when no windows are open.
struct DockPreviewView: View {
    @ObservedObject var viewModel: DockPreviewViewModel
    @State private var isHeaderHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .background(
            VisualEffectView(material: .hudWindow,
                             blendingMode: .behindWindow,
                             state: .active)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .fixedSize()
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if !viewModel.displayName.isEmpty || viewModel.appIcon != nil {
            HStack(spacing: 8) {
                if let icon = viewModel.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                Text(viewModel.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if isHeaderHovered && viewModel.headerActionsEnabled && !viewModel.snapshots.isEmpty {
                    headerActions
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .frame(minWidth: 200, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isHeaderHovered = $0 }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            headerButton(
                title: Localizer.string("hover.minimize_all"),
                systemImage: "rectangle.compress.vertical",
                action: { viewModel.onMinimizeAll?() }
            )
            headerButton(
                title: Localizer.string("hover.close_all"),
                systemImage: "xmark.circle.fill",
                tint: .red,
                action: { viewModel.onCloseAll?() }
            )
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
        .animation(.easeOut(duration: 0.14), value: isHeaderHovered)
    }

    private func headerButton(
        title: String,
        systemImage: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.snapshots.isEmpty {
            emptyState
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .padding(.top, 4)
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(viewModel.snapshots) { snap in
                    WindowThumbnailCell(
                        snapshot: snap,
                        appIcon: viewModel.appIcon,
                        size: viewModel.panelSize,
                        showCloseButton: viewModel.showCloseButton,
                        trafficLightEnabled: viewModel.trafficLightEnabled,
                        trafficLightSide: viewModel.trafficLightSide,
                        killButtonVisible: viewModel.killButtonVisible,
                        middleClickEnabled: viewModel.middleClickEnabled,
                        dragOutEnabled: viewModel.dragOutEnabled,
                        isMagnified: viewModel.isMagnified,
                        onActivate: { viewModel.onActivate?(snap) },
                        onClose: { viewModel.onClose?(snap) },
                        onMinimize: { viewModel.onMinimize?(snap) },
                        onZoom: { viewModel.onZoom?(snap) },
                        onKill: { viewModel.onKill?(snap) },
                        onDragOut: { viewModel.onDragOut?(snap) }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 6)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow.badge.plus")
                .foregroundStyle(.secondary)
            Text(Localizer.string("hover.no_open_windows"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}
