import AppKit
import Carbon
import ApplicationServices
import CoreGraphics
import SwiftUI

/// A thumbnail-based window switcher, bound to ⌥Tab (Option+Tab) rather than
/// the system's own ⌘Tab: actually intercepting/replacing ⌘Tab system-wide
/// means suppressing the real app switcher and risks leaving the system in a
/// broken state if anything about that goes wrong. ⌥Tab is unused by macOS,
/// gives the same "hold a modifier, tap to cycle, release to confirm" feel,
/// and switches between individual **windows** (not just apps) using the
/// live thumbnails `WindowDiscoveryService` already captures for Dock
/// previews.
@MainActor
final class WindowSwitcherService {
    private(set) var isRunning = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let windowDiscovery: WindowDiscoveryService

    private var panel: NSPanel?
    private var candidates: [DiscoveredWindow] = []
    private var selectedIndex = 0
    private let viewModel = WindowSwitcherViewModel()

    private static let tabKeyCode: UInt16 = 48

    init(windowDiscovery: WindowDiscoveryService) {
        self.windowDiscovery = windowDiscovery
    }

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
        dismissPanel(activate: false)
    }

    // MARK: - Event tap

    private func installEventTap() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<WindowSwitcherService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            NSLog("Augment: WindowSwitcherService – failed to create event tap (Accessibility?)")
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

        if type == .flagsChanged {
            // Option released while the switcher is open confirms the pick.
            if panel != nil && !event.flags.contains(.maskAlternate) {
                DispatchQueue.main.async { [weak self] in self?.dismissPanel(activate: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        // While the switcher is open: Esc cancels, arrows move the selection.
        if panel != nil {
            switch Int(keyCode) {
            case kVK_Escape:
                DispatchQueue.main.async { [weak self] in self?.dismissPanel(activate: false) }
                return nil
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
                let columns = viewModel.layout.columns
                let delta: Int
                switch Int(keyCode) {
                case kVK_LeftArrow: delta = -1
                case kVK_RightArrow: delta = 1
                case kVK_UpArrow: delta = -columns
                default: delta = columns
                }
                DispatchQueue.main.async { [weak self] in self?.move(by: delta) }
                return nil
            default:
                break
            }
        }

        guard keyCode == Self.tabKeyCode, event.flags.contains(.maskAlternate) else {
            return Unmanaged.passUnretained(event)
        }

        let backward = event.flags.contains(.maskShift)
        DispatchQueue.main.async { [weak self] in self?.advance(backward: backward) }
        return nil
    }

    // MARK: - Switching

    private func advance(backward: Bool) {
        if panel == nil {
            open()
            return
        }
        guard !candidates.isEmpty else { return }
        move(by: backward ? -1 : 1)
    }

    private func move(by delta: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + candidates.count) % candidates.count
        viewModel.selectedIndex = selectedIndex
    }

    /// Only real app windows, front to back — never the Dock, Control Center
    /// or other system surfaces that also own on-screen windows.
    private func switchableWindows() -> [DiscoveredWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let regularPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map(\.processIdentifier))
        return windowDiscovery.windows().filter {
            $0.layer == 0 && $0.ownerPID != ownPID && regularPIDs.contains($0.ownerPID)
        }
    }

    private func open() {
        candidates = switchableWindows()
        guard !candidates.isEmpty else { return }
        selectedIndex = candidates.count > 1 ? 1 : 0

        let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        guard let screen else { return }
        let layout = SwitcherLayout(count: candidates.count, available: screen.visibleFrame.size)

        viewModel.layout = layout
        viewModel.selectedIndex = selectedIndex
        viewModel.items = candidates.map { window in
            let app = NSRunningApplication(processIdentifier: window.ownerPID)
            let title = (window.title?.isEmpty == false ? window.title : nil) ?? app?.localizedName ?? window.ownerName
            return WindowSwitcherItem(id: window.id, title: title, appName: app?.localizedName ?? window.ownerName,
                                      appIcon: app?.icon, thumbnail: nil)
        }

        let hostingView = NSHostingView(rootView: WindowSwitcherView(viewModel: viewModel))
        hostingView.sizingOptions = []
        let size = layout.panelSize
        hostingView.frame = NSRect(origin: .zero, size: size)
        let origin = CGPoint(x: screen.visibleFrame.midX - size.width / 2,
                             y: screen.visibleFrame.midY - size.height / 2)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.contentView = hostingView
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.orderFrontRegardless()
        panel = p

        // Show instantly with icons; fill in live thumbnails off the main thread.
        let windows = candidates
        let discovery = windowDiscovery
        let maxDimension = layout.thumbnailSize.width * (screen.backingScaleFactor)
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let images = windows.map { discovery.captureThumbnail(for: $0.id, maxDimension: maxDimension) }
            DispatchQueue.main.async {
                guard let self, self.panel != nil, self.viewModel.items.count == images.count else { return }
                for i in images.indices { self.viewModel.items[i].thumbnail = images[i] }
            }
        }
    }

    private func dismissPanel(activate: Bool) {
        defer {
            panel?.orderOut(nil)
            panel = nil
            candidates = []
            viewModel.items = []
        }
        guard activate, candidates.indices.contains(selectedIndex) else { return }
        windowDiscovery.focusWindow(candidates[selectedIndex])
    }
}

// MARK: - Layout

/// Fits every window on screen: as many columns as the screen allows, extra
/// rows as needed, and smaller tiles only when even that doesn't fit.
struct SwitcherLayout: Equatable {
    let columns: Int
    let rows: Int
    let thumbnailSize: CGSize

    static let padding: CGFloat = 22
    static let spacing: CGFloat = 14
    static let labelHeight: CGFloat = 26
    static let tileInset: CGFloat = 8

    init(count: Int, available: CGSize) {
        let maxWidth = available.width * 0.86
        let maxHeight = available.height * 0.78
        var thumb = CGSize(width: 220, height: 138)
        var cols = 1, rows = 1
        while true {
            let tileW = thumb.width + Self.tileInset * 2
            let tileH = thumb.height + Self.labelHeight + Self.tileInset * 2
            cols = max(1, min(count, Int((maxWidth - Self.padding * 2 + Self.spacing) / (tileW + Self.spacing))))
            rows = Int(ceil(Double(count) / Double(cols)))
            let height = CGFloat(rows) * tileH + CGFloat(rows - 1) * Self.spacing + Self.padding * 2
            if height <= maxHeight || thumb.width <= 110 { break }
            thumb = CGSize(width: thumb.width * 0.88, height: thumb.height * 0.88)
        }
        columns = cols
        self.rows = rows
        thumbnailSize = CGSize(width: thumb.width.rounded(), height: thumb.height.rounded())
    }

    var tileSize: CGSize {
        CGSize(width: thumbnailSize.width + Self.tileInset * 2,
               height: thumbnailSize.height + Self.labelHeight + Self.tileInset * 2)
    }

    var panelSize: CGSize {
        CGSize(width: CGFloat(columns) * tileSize.width + CGFloat(columns - 1) * Self.spacing + Self.padding * 2,
               height: CGFloat(rows) * tileSize.height + CGFloat(rows - 1) * Self.spacing + Self.padding * 2)
    }
}

// MARK: - UI

private struct WindowSwitcherItem: Identifiable {
    let id: CGWindowID
    let title: String
    let appName: String
    let appIcon: NSImage?
    var thumbnail: CGImage?
}

@MainActor
private final class WindowSwitcherViewModel: ObservableObject {
    @Published var items: [WindowSwitcherItem] = []
    @Published var selectedIndex = 0
    @Published var layout = SwitcherLayout(count: 1, available: CGSize(width: 800, height: 600))
}

private struct WindowSwitcherView: View {
    @ObservedObject var viewModel: WindowSwitcherViewModel

    var body: some View {
        let layout = viewModel.layout
        let columns = Array(repeating: GridItem(.fixed(layout.tileSize.width), spacing: SwitcherLayout.spacing),
                            count: layout.columns)
        LazyVGrid(columns: columns, spacing: SwitcherLayout.spacing) {
            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                tile(item, selected: index == viewModel.selectedIndex, layout: layout)
            }
        }
        .padding(SwitcherLayout.padding)
        .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .top)
        .modifier(SwitcherBackground())
    }

    private func tile(_ item: WindowSwitcherItem, selected: Bool, layout: SwitcherLayout) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if let cg = item.thumbnail {
                    Image(decorative: cg, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                } else if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .opacity(0.9)
                }
            }
            .frame(width: layout.thumbnailSize.width, height: layout.thumbnailSize.height)

            HStack(spacing: 6) {
                if let icon = item.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(item.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: layout.thumbnailSize.width, height: SwitcherLayout.labelHeight - 6)
        }
        .padding(SwitcherLayout.tileInset)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Color.primary.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

/// macOS 26+ Liquid Glass, with a vibrant material fallback.
private struct SwitcherBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}
