import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings for the display, keep-awake, notch, clipboard and Finder extras.

/// Keyboard keys for external monitors + the day/night brightness schedule.
struct DisplayExtrasSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Section {
            ToggleRow(
                title: Localizer.string("displays.keys_title"),
                subtitle: Localizer.string("displays.keys_desc"),
                systemImage: "keyboard",
                tint: .gray,
                isOn: $preferences.displayKeysEnabled,
                requires: [.accessibility]
            )
        } header: {
            Text(Localizer.string("displays.keys_section"))
        }

        Section {
            ToggleRow(
                title: Localizer.string("displays.schedule_title"),
                subtitle: Localizer.string("displays.schedule_desc"),
                systemImage: "sun.and.horizon",
                tint: .orange,
                isOn: $preferences.brightnessScheduleEnabled
            )
            if preferences.brightnessScheduleEnabled {
                scheduleRow(title: Localizer.string("displays.schedule_day"), icon: "sun.max",
                            minutes: $preferences.brightnessDayStart, level: $preferences.brightnessDayLevel)
                scheduleRow(title: Localizer.string("displays.schedule_night"), icon: "moon",
                            minutes: $preferences.brightnessNightStart, level: $preferences.brightnessNightLevel)
            }
        } header: {
            Text(Localizer.string("displays.schedule_section"))
        }
    }

    private func scheduleRow(title: String, icon: String, minutes: Binding<Double>, level: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                DatePicker("", selection: Binding(
                    get: { Self.date(fromMinutes: minutes.wrappedValue) },
                    set: { minutes.wrappedValue = Self.minutes(from: $0); BrightnessScheduler.shared.reapply() }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.field)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary).font(.caption)
                Slider(value: Binding(get: { level.wrappedValue },
                                      set: { level.wrappedValue = $0 }),
                       in: 0.05...1) { editing in
                    if !editing { BrightnessScheduler.shared.reapply() }
                }
                Image(systemName: "sun.max").foregroundStyle(.secondary).font(.caption)
                Text("\(Int(level.wrappedValue * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.leading, 38)
    }

    static func date(fromMinutes m: Double) -> Date {
        Calendar.current.date(bySettingHour: Int(m) / 60, minute: Int(m) % 60, second: 0, of: Date()) ?? Date()
    }

    static func minutes(from date: Date) -> Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}

/// Amphetamine-style triggers and options for keep awake.
struct AwakeOptionsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences
    @ObservedObject private var caffeinate = CaffeinateService.shared

    var body: some View {
        Section {
            Toggle(isOn: $preferences.awakeOnPower) {
                Label(Localizer.string("awake.on_power"), systemImage: "powerplug")
            }
            Toggle(isOn: $preferences.awakeWhileDownloading) {
                Label(Localizer.string("awake.downloading"), systemImage: "arrow.down.circle")
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(Localizer.string("awake.apps"), systemImage: "app.badge.checkmark")
                    Spacer()
                    Button(Localizer.string("awake.add_app")) { addApp() }
                        .controlSize(.small)
                }
                ForEach(preferences.awakeWhileApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Text(bundleID)
                        }
                        Spacer()
                        Button {
                            preferences.awakeWhileApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 28)
                }
            }
            if let reason = caffeinate.automaticReason {
                Label(reason, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        } header: {
            Text(Localizer.string("awake.auto_section"))
        } footer: {
            Text(Localizer.string("awake.auto_footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle(isOn: $preferences.awakeDisplayMaySleep) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localizer.string("awake.display_sleep"))
                    Text(Localizer.string("awake.display_sleep_desc")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $preferences.awakeLidClosed) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Localizer.string("awake.lid"))
                    Text(Localizer.string("awake.lid_desc")).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(Localizer.string("awake.options_section"))
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = Localizer.string("awake.add_app")
        guard panel.runModal() == .OK else { return }
        let ids = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        preferences.awakeWhileApps = Array(Set(preferences.awakeWhileApps + ids)).sorted()
    }
}

/// Meetings, screenshots-to-shelf and the clipboard panel.
struct NotchExtrasSections: View {
    @EnvironmentObject private var preferences: SharedPreferences
    @ObservedObject private var meetings = MeetingsService.shared

    var body: some View {
        Section {
            ToggleRow(
                title: Localizer.string("meetings.title"),
                subtitle: Localizer.string("meetings.desc"),
                systemImage: "calendar",
                tint: .red,
                isOn: $preferences.meetingsEnabled
            )
            if preferences.meetingsEnabled && !meetings.accessGranted {
                HStack {
                    Label(Localizer.string("meetings.no_access"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(Localizer.string("perm.open_settings")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                    .controlSize(.small)
                }
            }
            ToggleRow(
                title: Localizer.string("mirror.title"),
                subtitle: Localizer.string("mirror.desc"),
                systemImage: "camera",
                tint: .green,
                isOn: $preferences.notchMirrorEnabled
            )
            ToggleRow(
                title: Localizer.string("screenshots.title"),
                subtitle: Localizer.string("screenshots.desc"),
                systemImage: "camera.viewfinder",
                tint: .teal,
                isOn: $preferences.screenshotShelfEnabled
            )
        } header: {
            Text(Localizer.string("notch.extras_section"))
        }

        Section {
            ToggleRow(
                title: Localizer.string("clip.panel_title"),
                subtitle: Localizer.string("clip.panel_desc"),
                systemImage: "list.clipboard",
                tint: .blue,
                isOn: $preferences.clipboardPanelEnabled,
                requires: [.accessibility]
            )
        } header: {
            Text(Localizer.string("clip.section"))
        }
    }
}

/// Shows whether the Finder extension is on, with a button to turn it on —
/// without it none of the right-click items appear.
struct FinderExtensionStatusSection: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let enabled = FinderExtensionStatus.isEnabled
            Section {
                HStack(spacing: 10) {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(enabled ? .green : .orange)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Localizer.string(enabled ? "finderext.on" : "finderext.off"))
                        if !enabled {
                            Text(Localizer.string("finderext.off_desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if !enabled {
                        Button(Localizer.string("finderext.enable")) { FinderExtensionStatus.openSettings() }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Copy path / Terminal menu items.
struct FinderExtrasSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Section {
            ToggleRow(
                title: Localizer.string("finder.extra_title"),
                subtitle: Localizer.string("finder.extra_desc"),
                systemImage: "terminal",
                tint: .gray,
                isOn: $preferences.finderExtraMenuEnabled
            )
        } header: {
            Text(Localizer.string("finder.extras_section"))
        }
    }
}
