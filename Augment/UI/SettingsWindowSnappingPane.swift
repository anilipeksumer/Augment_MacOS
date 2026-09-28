import AppKit
import Carbon
import SwiftUI

// MARK: - Window Snapping

struct WindowSnappingSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    @State private var shortcuts: [String: SnapShortcut] = [:]
    @State private var recordingDirection: SnapDirection?

    var body: some View {
        Group {

            Section {
                ToggleRow(
                    title: Localizer.string("snapping.enable"),
                    subtitle: Localizer.string("snapping.enable_desc"),
                    systemImage: "keyboard",
                    tint: .cyan,
                    isOn: $preferences.windowSnappingEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.windowSnappingEnabled)
                )
            } header: {
                Text(Localizer.string("snapping.toggle"))
            }

            Section {
                ForEach(SnapDirection.allCases) { direction in
                    HStack(spacing: 12) {
                        Image(systemName: iconForDirection(direction))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.cyan)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(direction.displayName)
                            Text(shortcutLabel(for: direction))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if recordingDirection == direction {
                            Text(Localizer.string("snapping.press"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.orange.opacity(0.15))
                                )
                        } else {
                            Button {
                                recordingDirection = direction
                            } label: {
                                Text(Localizer.string("snapping.change"))
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button {
                            resetShortcut(for: direction)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help(Localizer.string("snapping.reset_help"))
                    }
                    .disabled(!preferences.windowSnappingEnabled)
                }
            } header: {
                Text(Localizer.string("snapping.shortcuts"))
            } footer: {
                Text(Localizer.string("snapping.shortcuts_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SnapPreview()
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            } header: {
                Text(Localizer.string("snapping.preview"))
            }

            Section {
                ToggleRow(
                    title: Localizer.string("cutpaste.window_title"),
                    subtitle: Localizer.string("cutpaste.window_desc"),
                    systemImage: "macwindow.and.cursorarrow",
                    tint: .indigo,
                    isOn: $preferences.windowCutPasteEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.windowCutPasteEnabled)
                )
                HStack {
                    Text(Localizer.string("cutpaste.cut"))
                    Spacer()
                    Text("⌃⌘X").foregroundStyle(.secondary)
                }
                .font(.caption)
                HStack {
                    Text(Localizer.string("cutpaste.paste"))
                    Spacer()
                    Text("⌃⌘V").foregroundStyle(.secondary)
                }
                .font(.caption)
            } header: {
                Text(Localizer.string("cutpaste.section"))
            } footer: {
                Text(Localizer.string("cutpaste.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ToggleRow(
                    title: Localizer.string("snaplayouts.title"),
                    subtitle: Localizer.string("snaplayouts.desc"),
                    systemImage: "square.grid.2x2",
                    tint: .teal,
                    isOn: $preferences.snapLayoutsEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.snapLayoutsEnabled)
                )
                HStack {
                    Text(Localizer.string("snaplayouts.trigger"))
                    Spacer()
                    Text("⌃⌥Space").foregroundStyle(.secondary)
                }
                .font(.caption)
            } header: {
                Text(Localizer.string("snaplayouts.section"))
            } footer: {
                Text(Localizer.string("snaplayouts.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ToggleRow(
                    title: Localizer.string("switcher.title"),
                    subtitle: Localizer.string("switcher.desc"),
                    systemImage: "rectangle.stack",
                    tint: .purple,
                    isOn: $preferences.windowSwitcherEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.windowSwitcherEnabled)
                )
                HStack {
                    Text(Localizer.string("switcher.trigger"))
                    Spacer()
                    Text("⌥Tab").foregroundStyle(.secondary)
                }
                .font(.caption)
            } header: {
                Text(Localizer.string("switcher.section"))
            } footer: {
                Text(Localizer.string("switcher.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadShortcuts() }
        .background(
            ShortcutCaptureView(
                isRecording: recordingDirection != nil,
                onCapture: { modifiers, keyCode in
                    guard let dir = recordingDirection else { return }
                    shortcuts[dir.rawValue] = SnapShortcut(
                        modifiers: UInt64(modifiers.rawValue),
                        keyCode: keyCode
                    )
                    saveShortcuts()
                    recordingDirection = nil
                },
                onCancel: { recordingDirection = nil }
            )
        )
    }

    private func iconForDirection(_ direction: SnapDirection) -> String {
        switch direction {
        case .left:  return "rectangle.lefthalf.inset.filled"
        case .right: return "rectangle.righthalf.inset.filled"
        case .up:    return "rectangle.inset.filled"
        case .down:  return "rectangle.center.inset.filled"
        }
    }

    private func shortcutLabel(for direction: SnapDirection) -> String {
        let shortcut = shortcuts[direction.rawValue] ?? SnapShortcut(
            modifiers: direction.defaultModifiers.rawValue,
            keyCode: direction.defaultKeyCode
        )
        return modifierSymbols(for: shortcut.modifiers) + keyName(for: shortcut.keyCode)
    }

    private func modifierSymbols(for flags: UInt64) -> String {
        var s = ""
        let f = CGEventFlags(rawValue: flags)
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            if let chars = keyCodeToString(keyCode) {
                return chars.uppercased()
            }
            return "Key \(keyCode)"
        }
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { rawBuf -> String? in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            let status = UCKeyTranslate(
                ptr,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    private func resetShortcut(for direction: SnapDirection) {
        shortcuts[direction.rawValue] = SnapShortcut(
            modifiers: direction.defaultModifiers.rawValue,
            keyCode: direction.defaultKeyCode
        )
        saveShortcuts()
    }

    private func loadShortcuts() {
        let json = preferences.windowSnappingShortcuts
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SnapShortcutMap.self, from: data)
        else {
            // Populate defaults.
            for dir in SnapDirection.allCases {
                shortcuts[dir.rawValue] = SnapShortcut(
                    modifiers: dir.defaultModifiers.rawValue,
                    keyCode: dir.defaultKeyCode
                )
            }
            return
        }
        shortcuts = decoded
        // Fill in any missing directions with defaults.
        for dir in SnapDirection.allCases where shortcuts[dir.rawValue] == nil {
            shortcuts[dir.rawValue] = SnapShortcut(
                modifiers: dir.defaultModifiers.rawValue,
                keyCode: dir.defaultKeyCode
            )
        }
    }

    private func saveShortcuts() {
        guard let data = try? JSONEncoder().encode(shortcuts),
              let json = String(data: data, encoding: .utf8) else { return }
        preferences.windowSnappingShortcuts = json
    }
}

/// A tiny schematic showing the four snap zones.
struct SnapPreview: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let gap: CGFloat = 4

                // Left half
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cyan.opacity(0.25))
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 10, weight: .bold))
                            Text(Localizer.string("snapping.left"))
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.cyan)
                    )
                    .frame(width: w / 2 - gap * 1.5, height: h - gap * 2)
                    .position(x: w / 4, y: h / 2)

                // Right half
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.cyan.opacity(0.25))
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.right")
                                .font(.system(size: 10, weight: .bold))
                            Text(Localizer.string("snapping.right"))
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(.cyan)
                    )
                    .frame(width: w / 2 - gap * 1.5, height: h - gap * 2)
                    .position(x: w * 3 / 4, y: h / 2)
            }
        }
    }
}

/// Invisible helper view that captures key events for shortcut recording.
/// It installs a local NSEvent monitor when `isRecording` is true.
struct ShortcutCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onCapture: (NSEvent.ModifierFlags, UInt16) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            if context.coordinator.monitor == nil {
                context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
                    matching: .keyDown
                ) { [onCapture, onCancel] event in
                    if event.keyCode == 53 { // Escape
                        onCancel()
                        return nil
                    }
                    // Require at least one modifier.
                    let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    guard !mods.isEmpty else { return event }
                    onCapture(mods, event.keyCode)
                    return nil
                }
            }
        } else {
            if let m = context.coordinator.monitor {
                NSEvent.removeMonitor(m)
                context.coordinator.monitor = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var monitor: Any?
        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

