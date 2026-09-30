import AppKit
import SwiftUI

// The eight Settings pages. Each feature lives on the page for the part of
// macOS it changes; the page bodies reuse the `…SettingsSections` groups.

struct DockPage: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("page.dock"), subtitle: Localizer.string("page.dock_sub"),
                           systemImage: "dock.rectangle", tint: .blue)
            }
            Section {
                ToggleRow(
                    title: Localizer.string("feature.hover_title"),
                    subtitle: Localizer.string("feature.hover_subtitle"),
                    systemImage: "rectangle.stack.badge.play",
                    tint: .blue,
                    isOn: $preferences.windowPreviewsEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.windowPreviewsEnabled)
                )
            } header: {
                Text(Localizer.string("page.dock_previews"))
            }
            if preferences.windowPreviewsEnabled {
                HoverSettingsSections()
                WindowControlsSettingsSections()
            }
            DockClickSettingsSections()
            DockLockSettingsSections()
        }
        .formStyle(.grouped)
    }
}

struct WindowsPage: View {
    @EnvironmentObject private var preferences: SharedPreferences
    @ObservedObject private var desktop = ShowDesktopService.shared

    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("page.windows"), subtitle: Localizer.string("page.windows_sub"),
                           systemImage: "macwindow.on.rectangle", tint: .cyan)
            }
            Section {
                ToggleRow(title: Localizer.string("desktop.title"),
                          subtitle: Localizer.string("desktop.description"),
                          systemImage: "menubar.dock.rectangle", tint: .cyan,
                          isOn: $preferences.showDesktopEnabled)
                    .disabled(!desktop.isSupported)
                if !desktop.isSupported {
                    Text(Localizer.string("desktop.unsupported")).foregroundStyle(.secondary)
                } else if preferences.showDesktopEnabled && !desktop.shortcutAvailable {
                    Text(Localizer.string("desktop.conflict")).foregroundStyle(.orange)
                }
            }
            WindowSnappingSettingsSections()
        }
        .formStyle(.grouped)
    }
}

struct FinderPage: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("page.finder"), subtitle: Localizer.string("page.finder_sub"),
                           systemImage: "folder.fill", tint: .green)
            }
            FinderExtensionStatusSection()
            FinderSettingsSections()
            Section {
                ToggleRow(
                    title: Localizer.string("cutpaste.file_title"),
                    subtitle: Localizer.string("cutpaste.file_desc"),
                    systemImage: "scissors",
                    tint: .indigo,
                    isOn: $preferences.fileCutPasteEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.fileCutPasteEnabled)
                )
            } header: {
                Text(Localizer.string("page.finder_cut"))
            }
            FinderExtrasSections()
        }
        .formStyle(.grouped)
    }
}

struct NotchPage: View {
    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("notch.title"), subtitle: Localizer.string("notch.subtitle"),
                           systemImage: "platter.filled.top.iphone", tint: .purple)
            }
            NotchSettingsSections()
            NotchExtrasSections()
        }
        .formStyle(.grouped)
    }
}

struct SoundDisplayPage: View {
    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("page.sound"), subtitle: Localizer.string("page.sound_sub"),
                           systemImage: "speaker.wave.2.fill", tint: .red)
            }
            VolumeMixerSettingsSections()
            ExternalDisplaySettingsSections()
            DisplayExtrasSections()
        }
        .formStyle(.grouped)
    }
}

/// What the quick panel under Augment's menu bar icon shows.
struct MenuBarPage: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("page.menubar"), subtitle: Localizer.string("page.menubar_sub"),
                           systemImage: "menubar.rectangle", tint: .indigo)
            }
            Section {
                moduleToggle("stats.title", icon: "cpu", tint: .teal, isOn: $preferences.quickPanelStats)
                moduleToggle("quick.displays", icon: "sun.max.fill", tint: .yellow, isOn: $preferences.quickPanelDisplays)
                moduleToggle("quick.sound", icon: "speaker.wave.2.fill", tint: .red, isOn: $preferences.quickPanelSound)
                moduleToggle("quick.microphone", icon: "mic.fill", tint: .pink, isOn: $preferences.quickPanelMic)
                moduleToggle("meetings.title", icon: "calendar", tint: .red, isOn: $preferences.quickPanelMeetings)
                moduleToggle("page.awake_title", icon: "cup.and.saucer.fill", tint: .orange, isOn: $preferences.quickPanelAwake)
            } header: {
                Text(Localizer.string("quick.modules"))
            } footer: {
                Text(Localizer.string("quick.modules_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func moduleToggle(_ key: String, icon: String, tint: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
                Text(Localizer.string(key))
            }
        }
        .toggleStyle(.switch)
    }
}

/// Keep awake: the manual switch and duration, automatic triggers, options.
struct AwakePage: View {
    @ObservedObject private var caffeinate = CaffeinateService.shared

    var body: some View {
        Form {
            Section {
                PaneHeader(title: Localizer.string("page.awake_title"), subtitle: Localizer.string("page.awake_page_sub"),
                           systemImage: "cup.and.saucer.fill", tint: .orange)
            }
            Section {
                Toggle(isOn: Binding(get: { caffeinate.isActive }, set: { $0 ? caffeinate.activate() : caffeinate.deactivate() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Localizer.string("menu.caffeinate"))
                        Text(Localizer.string("page.awake_sub")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Picker(Localizer.string("quick.awake_duration"), selection: Binding(
                    get: { caffeinate.isActive ? (caffeinate.selectedPreset ?? -1) : -2 },
                    set: { tag in
                        if tag == -2 { caffeinate.deactivate() }
                        else { caffeinate.activate(for: tag < 0 ? nil : TimeInterval(tag)) }
                    }
                )) {
                    Text(Localizer.string("quick.off")).tag(-2)
                    ForEach(Array(CaffeinateService.presets.enumerated()), id: \.offset) { _, preset in
                        Text(NotchContentView.durationTitle(preset)).tag(preset.map { Int($0) } ?? -1)
                    }
                }
            } header: {
                Text(Localizer.string("awake.manual_section"))
            }
            AwakeOptionsSections()
        }
        .formStyle(.grouped)
    }
}

struct ExternalDisplaySettingsSections: View {
    @ObservedObject private var displays = DisplayBrightnessService.shared

    var body: some View {
        Section {
            if displays.displays.isEmpty {
                Text(Localizer.string("displays.none")).foregroundStyle(.secondary)
            }
            ForEach(displays.displays) { display in
                DisplayBrightnessRow(display: display)
            }
        } header: {
            HStack {
                Text(Localizer.string("displays.section"))
                Spacer()
                Button(Localizer.string("displays.rescan")) { displays.refresh() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } footer: {
            Text(Localizer.string("displays.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { displays.refresh() }
    }
}

struct DisplayBrightnessRow: View {
    let display: ManagedDisplay
    @ObservedObject private var displays = DisplayBrightnessService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(display.name)
                Spacer()
                Text(Self.methodLabel(display.method))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary).font(.caption)
                Slider(value: Binding(
                    get: { display.brightness },
                    set: { displays.setBrightness($0, for: display.id) }
                ), in: 0...1)
                Image(systemName: "sun.max").foregroundStyle(.secondary).font(.caption)
                Text("\(Int(display.brightness * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    static func methodLabel(_ method: ManagedDisplay.Method) -> String {
        switch method {
        case .native: return Localizer.string("displays.method_native")
        case .ddc: return Localizer.string("displays.method_ddc")
        case .software: return Localizer.string("displays.method_software")
        }
    }
}
