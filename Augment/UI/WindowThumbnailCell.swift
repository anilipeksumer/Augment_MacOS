import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Single live-window cell rendered inside the Dock preview panel.
///
/// Shows the captured thumbnail (or a simple placeholder) plus the
/// window's title underneath, matching the spacing and typography Apple
/// uses in App Exposé and Mission Control. The cell reacts to hover to
/// surface a close affordance, optional macOS-style traffic-light controls
/// (close / minimize / fullscreen / kill), middle-click-to-close, and
/// drag-out-to-activate.
struct WindowThumbnailCell: View {
    let snapshot: WindowSnapshot
    let appIcon: NSImage?
    let size: PreviewPanelSize
    let showCloseButton: Bool
    let trafficLightEnabled: Bool
    let trafficLightSide: TrafficLightSide
    let killButtonVisible: Bool
    let middleClickEnabled: Bool
    let dragOutEnabled: Bool
    /// When set, the cell renders at the magnified Finder-like size while
    /// passing through the same control affordances.
    let isMagnified: Bool

    var onActivate: () -> Void = {}
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onZoom: () -> Void = {}
    var onKill: () -> Void = {}
    var onDragOut: () -> Void = {}

    @State private var isHovered: Bool = false
    @State private var isControlBarHovered: Bool = false

    private var cellWidth: CGFloat {
        isMagnified ? size.magnifiedSize.width : size.thumbnailWidth
    }
    private var cellHeight: CGFloat {
        isMagnified ? size.magnifiedSize.height : size.thumbnailHeight
    }
    private let cornerRadius: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                thumbnail
                    .frame(width: cellWidth, height: cellHeight)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isHovered ? 0.3 : 0.1),
                                          lineWidth: isHovered ? 1 : 0.5)
                    )

                controlOverlay
                    .padding(7)
                    .opacity(isHovered ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            }
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.14), value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture { onActivate() }
            .conditionalDrag(enabled: dragOutEnabled, onDragStarted: onDragOut)
            .overlay(middleClickOverlay)

            Text(displayTitle)
                .font(.system(size: isMagnified ? 13 : 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: cellWidth, alignment: .leading)
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        thumbnailContent
            .overlay(alignment: .bottom) {
                if snapshot.window.isMinimized {
                    Label(Localizer.string("hover.minimized"), systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 6)
                }
            }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let image = snapshot.thumbnail {
            Image(decorative: image, scale: backingScale, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: cellWidth, maxHeight: cellHeight)
        } else if let icon = appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: isMagnified ? 64 : 48, height: isMagnified ? 64 : 48)
                .frame(maxWidth: cellWidth, maxHeight: cellHeight)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: isMagnified ? 56 : 28, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlOverlay: some View {
        if trafficLightEnabled {
            HStack {
                if trafficLightSide == .leading {
                    trafficLightCluster
                    Spacer(minLength: 0)
                    if killButtonVisible { killButton }
                } else {
                    if killButtonVisible { killButton }
                    Spacer(minLength: 0)
                    trafficLightCluster
                }
            }
            .frame(width: cellWidth - 14, height: 22, alignment: .top)
        } else if showCloseButton {
            HStack {
                Spacer()
                legacyCloseButton
            }
            .frame(width: cellWidth - 14)
        }
    }

    private var trafficLightCluster: some View {
        HStack(spacing: 6) {
            trafficLightDot(color: .red, symbol: "xmark", help: "Close window", action: onClose)
            trafficLightDot(color: .yellow, symbol: "minus", help: "Minimize", action: onMinimize)
            trafficLightDot(color: .green, symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom / Fullscreen", action: onZoom)
        }
        .onHover { isControlBarHovered = $0 }
    }

    private func trafficLightDot(
        color: Color,
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.95))
                    .frame(width: 12, height: 12)
                Image(systemName: symbol)
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .opacity(isControlBarHovered ? 1 : 0)
            }
            .overlay(
                Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var killButton: some View {
        Button(action: onKill) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 18, height: 18)
                Image(systemName: "bolt.slash.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .buttonStyle(.plain)
        .help("Force quit app")
        .accessibilityLabel("Force quit app")
    }

    private var legacyCloseButton: some View {
        Button(action: onClose) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 18, height: 18)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .help("Close window")
        .accessibilityLabel("Close window")
    }

    // MARK: - Middle click

    @ViewBuilder
    private var middleClickOverlay: some View {
        if middleClickEnabled {
            MouseEventCatcher(onMiddleClick: { onClose() })
                .allowsHitTesting(true)
        } else {
            EmptyView()
        }
    }

    // MARK: - Helpers

    private var displayTitle: String {
        if let title = snapshot.window.title, !title.isEmpty {
            return title
        }
        return snapshot.window.ownerName
    }

    private var backingScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }
}

private extension View {
    /// Conditionally attaches a SwiftUI `.onDrag` modifier so we can keep
    /// the cell drag-free when the user disables that feature in Settings.
    @ViewBuilder
    func conditionalDrag(enabled: Bool, onDragStarted: @escaping () -> Void) -> some View {
        if enabled {
            self.onDrag {
                onDragStarted()
                // Carry an empty itemProvider; the side effect (focus the
                // window) is what matters – nothing is actually transferred
                // to the drop target.
                let provider = NSItemProvider(object: "augment.window" as NSString)
                provider.suggestedName = "Augment Window"
                return provider
            }
        } else {
            self
        }
    }
}
