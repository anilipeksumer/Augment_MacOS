import AppKit
import SwiftUI

// MARK: - Displays / Dock Lock

struct DockLockSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    @State private var screens: [ScreenIdentity] = ScreenGeometry.allIdentities()

    var body: some View {
        Group {

            Section {
                ToggleRow(
                    title: Localizer.string("displays.lock"),
                    subtitle: Localizer.string("displays.lock_desc"),
                    systemImage: "lock.fill",
                    tint: .pink,
                    isOn: $preferences.dockLockEnabled
                )
            } header: {
                Text(Localizer.string("displays.dock_lock"))
            } footer: {
                Text(Localizer.string("displays.dock_lock_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ScreenLayoutPreview(
                    screens: screens,
                    selectedKeys: Set(preferences.lockedScreenIdentifiers),
                    onToggle: { identity in
                        toggle(identity)
                    },
                    enabled: preferences.dockLockEnabled
                )
                .frame(height: 220)

                ForEach(screens) { screen in
                    Toggle(isOn: bindingForScreen(screen)) {
                        HStack(spacing: 10) {
                            Image(systemName: "display")
                                .foregroundStyle(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(screen.localizedName)
                                Text("\(Localizer.string("displays.id")) \(screen.displayID)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(!preferences.dockLockEnabled)
                }
                Button {
                    screens = ScreenGeometry.allIdentities()
                } label: {
                    Label(Localizer.string("displays.refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            } header: {
                Text(Localizer.string("displays.connected"))
            } footer: {
                Text(Localizer.string("displays.fallback"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { screens = ScreenGeometry.allIdentities() }
    }

    private func bindingForScreen(_ screen: ScreenIdentity) -> Binding<Bool> {
        Binding(
            get: { preferences.lockedScreenIdentifiers.contains(screen.storageKey) },
            set: { isOn in
                if isOn {
                    if !preferences.lockedScreenIdentifiers.contains(screen.storageKey) {
                        preferences.lockedScreenIdentifiers.append(screen.storageKey)
                    }
                } else {
                    preferences.lockedScreenIdentifiers.removeAll(where: { $0 == screen.storageKey })
                }
            }
        )
    }

    private func toggle(_ identity: ScreenIdentity) {
        let key = identity.storageKey
        if preferences.lockedScreenIdentifiers.contains(key) {
            preferences.lockedScreenIdentifiers.removeAll(where: { $0 == key })
        } else {
            preferences.lockedScreenIdentifiers.append(key)
        }
    }
}

struct ScreenLayoutPreview: View {
    let screens: [ScreenIdentity]
    let selectedKeys: Set<String>
    let onToggle: (ScreenIdentity) -> Void
    let enabled: Bool

    var body: some View {
        GeometryReader { geo in
            let bounding = unionFrame()
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                ForEach(zippedScreenFrames(), id: \.0.storageKey) { screen, frame in
                    let scaled = scale(frame, in: geo.size, bounding: bounding)
                    let isSelected = selectedKeys.contains(screen.storageKey)
                    Button {
                        onToggle(screen)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isSelected ? Color.pink.opacity(0.35) : Color.primary.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(isSelected ? Color.pink : Color.primary.opacity(0.18),
                                                       lineWidth: isSelected ? 2 : 1)
                                )
                            VStack(spacing: 2) {
                                Image(systemName: isSelected ? "lock.fill" : "display")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.pink : .secondary)
                                Text(screen.localizedName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(6)
                        }
                        .frame(width: scaled.width, height: scaled.height)
                        .position(x: scaled.midX, y: scaled.midY)
                    }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                }
            }
        }
    }

    private func screenFrames() -> [CGRect] {
        NSScreen.screens.compactMap { screen -> CGRect? in
            guard let identity = ScreenGeometry.identity(of: screen) else { return nil }
            guard screens.contains(where: { $0.displayID == identity.displayID }) else { return nil }
            return screen.frame
        }
    }

    private func zippedScreenFrames() -> [(ScreenIdentity, CGRect)] {
        screens.compactMap { id -> (ScreenIdentity, CGRect)? in
            let match = NSScreen.screens.first(where: { ns in
                ScreenGeometry.identity(of: ns)?.displayID == id.displayID
            })
            guard let frame = match?.frame else { return nil }
            return (id, frame)
        }
    }

    private func unionFrame() -> CGRect {
        let frames = screenFrames()
        guard let first = frames.first else { return .zero }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    private func scale(_ frame: CGRect, in size: CGSize, bounding: CGRect) -> CGRect {
        guard bounding.width > 0, bounding.height > 0 else { return .zero }
        let aspect = bounding.width / bounding.height
        let safeWidth = max(0, size.width - 20)
        let safeHeight = max(0, size.height - 20)
        let canvasWidth = min(safeWidth, safeHeight * aspect)
        let canvasHeight = aspect > 0 ? canvasWidth / aspect : 0
        let xScale = canvasWidth / bounding.width
        let yScale = canvasHeight / bounding.height
        let dx = (frame.minX - bounding.minX) * xScale + (size.width - canvasWidth) / 2
        let dy = (bounding.maxY - frame.maxY) * yScale + (size.height - canvasHeight) / 2
        return CGRect(
            x: dx.isNaN ? 0 : dx,
            y: dy.isNaN ? 0 : dy,
            width: max(0, (frame.width * xScale).isNaN ? 0 : frame.width * xScale),
            height: max(0, (frame.height * yScale).isNaN ? 0 : frame.height * yScale)
        )
    }
}

