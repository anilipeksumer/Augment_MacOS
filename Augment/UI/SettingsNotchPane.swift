import AppKit
import SwiftUI

// MARK: - Notch Settings

struct NotchSettingsPane: View {
    @EnvironmentObject private var preferences: SharedPreferences

    @State private var hasNotchedScreen = false

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: Localizer.string("notch.title"),
                    subtitle: Localizer.string("notch.subtitle"),
                    systemImage: "platter.filled.top.iphone",
                    tint: .purple
                )
            }

            Section {
                ToggleRow(
                    title: Localizer.string("notch.enable"),
                    subtitle: Localizer.string("notch.enable_desc"),
                    systemImage: "sparkles.rectangle.stack",
                    tint: .purple,
                    isOn: $preferences.notchEnabled
                )

                if !hasNotchedScreen {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(Localizer.string("notch.no_notch"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text(Localizer.string("notch.toggle"))
            }

            Section {
                ToggleRow(
                    title: Localizer.string("notch.music"),
                    subtitle: Localizer.string("notch.music_desc"),
                    systemImage: "music.note",
                    tint: .pink,
                    isOn: $preferences.notchMusicWidget
                )
                .disabled(!preferences.notchEnabled)

                if preferences.notchMusicWidget {
                    Toggle(Localizer.string("notch.playback"), isOn: $preferences.notchMediaControlsEnabled)
                        .padding(.leading, 38)
                    Toggle(Localizer.string("notch.app_icon"), isOn: $preferences.notchShowAppIcon)
                        .padding(.leading, 38)
                    Toggle(Localizer.string("notch.album_art"), isOn: $preferences.notchShowAlbumArt)
                        .padding(.leading, 38)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Localizer.string("notch.hover"))
                        Spacer()
                        Text(String(format: "%.1fs", preferences.notchHoverDelay))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $preferences.notchHoverDelay, in: 0...1, step: 0.1)
                }
                .padding(.vertical, 4)
                .disabled(!preferences.notchEnabled)

                ToggleRow(
                    title: Localizer.string("notch.battery"),
                    subtitle: Localizer.string("notch.battery_desc"),
                    systemImage: "battery.75percent",
                    tint: .green,
                    isOn: $preferences.notchBatteryWidget
                )
                .disabled(!preferences.notchEnabled)

                if preferences.notchBatteryWidget {
                    Picker(Localizer.string("notch.battery_style"), selection: $preferences.notchBatteryStyle) {
                        Text(Localizer.string("notch.gauge")).tag("gauge")
                        Text(Localizer.string("notch.symbol")).tag("symbol")
                        Text(Localizer.string("notch.percent")).tag("percent")
                    }
                    .pickerStyle(.segmented)
                    .padding(.leading, 38)
                    .disabled(!preferences.notchEnabled)
                }

                ToggleRow(
                    title: Localizer.string("notch.calendar"),
                    subtitle: Localizer.string("notch.calendar_desc"),
                    systemImage: "calendar",
                    tint: .red,
                    isOn: $preferences.notchCalendarEnabled
                )
                .disabled(!preferences.notchEnabled)

                if preferences.notchCalendarEnabled {
                    Picker(Localizer.string("notch.calendar_style"), selection: $preferences.notchCalendarStyle) {
                        Text(Localizer.string("notch.compact")).tag("compact")
                        Text(Localizer.string("notch.badge")).tag("badge")
                        Text(Localizer.string("notch.text")).tag("text")
                    }
                    .pickerStyle(.segmented)
                    .padding(.leading, 38)
                    .disabled(!preferences.notchEnabled)
                }

                ToggleRow(
                    title: Localizer.string("notch.shelf"),
                    subtitle: Localizer.string("notch.shelf_desc"),
                    systemImage: "tray.and.arrow.down",
                    tint: .orange,
                    isOn: $preferences.notchShelfWidget
                )
                .disabled(!preferences.notchEnabled)
            } header: {
                Text(Localizer.string("notch.widgets"))
            } footer: {
                Text(Localizer.string("notch.widgets_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                NotchPreview()
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            } header: {
                Text(Localizer.string("notch.preview"))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasNotchedScreen = NSScreen.screens.contains(where: { $0.hasNotch })
        }
    }

}

/// Simple illustration of the notch concept.
struct NotchPreview: View {
    @EnvironmentObject private var preferences: SharedPreferences
    @State private var isHovering = false

    private var expanded: Bool {
        preferences.notchEnabled || isHovering
    }

    var body: some View {
        ZStack {
            // Screen
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.gray.opacity(0.12), Color.gray.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )

            // Notch
            VStack {
                RoundedRectangle(
                    cornerRadius: expanded ? 14 : 8,
                    style: .continuous
                )
                .fill(.black)
                .frame(
                    width: expanded ? 260 : 100,
                    height: expanded ? 54 : 20
                )
                .overlay(
                    Group {
                        if expanded {
                            previewWidgets
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                        }
                    }
                )
                .opacity(preferences.notchEnabled ? 1 : 0.55)
                .animation(.spring(response: 0.35, dampingFraction: 0.78), value: expanded)
                .onHover { hovering in
                    isHovering = hovering
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var previewWidgets: some View {
        HStack(spacing: 11) {
            if preferences.notchMusicWidget {
                Image(systemName: preferences.notchMediaControlsEnabled ? "play.fill" : "music.note")
                    .foregroundStyle(.pink)
                if preferences.notchShowAlbumArt {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.22))
                        .frame(width: 18, height: 18)
                }
                if preferences.notchShowAppIcon {
                    Image(systemName: "app.fill")
                        .foregroundStyle(.cyan)
                }
            }
            if preferences.notchCalendarEnabled {
                Image(systemName: preferences.notchCalendarStyle == "badge" ? "calendar.circle.fill" : "calendar")
                    .foregroundStyle(.red)
            }
            if preferences.notchShelfWidget {
                Image(systemName: "tray.and.arrow.down.fill")
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 4)
            if preferences.notchBatteryWidget {
                Image(systemName: preferences.notchBatteryStyle == "percent" ? "percent" : "battery.75percent")
                    .foregroundStyle(.green)
            }
            if !preferences.notchMusicWidget,
               !preferences.notchCalendarEnabled,
               !preferences.notchShelfWidget,
               !preferences.notchBatteryWidget {
                Text(Localizer.string("notch.no_widgets"))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 10, weight: .semibold))
    }

}
