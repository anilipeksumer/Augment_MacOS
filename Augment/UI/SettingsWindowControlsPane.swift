import AppKit
import SwiftUI

// MARK: - Window Controls

struct WindowControlsSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Group {

            Section {
                ToggleRow(
                    title: Localizer.string("controls.show"),
                    subtitle: Localizer.string("controls.show_desc"),
                    systemImage: "macwindow",
                    tint: .green,
                    isOn: $preferences.trafficLightEnabled
                )

                Picker(Localizer.string("controls.side"), selection: $preferences.trafficLightSide) {
                    ForEach(TrafficLightSide.allCases) { side in
                        Text(side.displayName).tag(side)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!preferences.trafficLightEnabled)

                ToggleRow(
                    title: Localizer.string("controls.force_quit"),
                    subtitle: Localizer.string("controls.force_quit_desc"),
                    systemImage: "bolt.slash.fill",
                    tint: .red,
                    isOn: $preferences.killButtonVisible
                )

                ToggleRow(
                    title: Localizer.string("controls.legacy"),
                    subtitle: Localizer.string("controls.legacy_desc"),
                    systemImage: "xmark.circle.fill",
                    tint: .orange,
                    isOn: $preferences.previewCloseButtonVisible
                )
            } header: {
                Text(Localizer.string("controls.layout"))
            } footer: {
                TrafficLightPreview(
                    side: preferences.trafficLightSide,
                    showKill: preferences.killButtonVisible,
                    enabled: preferences.trafficLightEnabled
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
        }
    }
}

struct TrafficLightPreview: View {
    let side: TrafficLightSide
    let showKill: Bool
    let enabled: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.gray.opacity(0.18), Color.gray.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom
                ))
                .frame(height: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )

            if enabled {
                HStack {
                    if side == .leading {
                        trafficLights
                        Spacer()
                        if showKill { killDot }
                    } else {
                        if showKill { killDot }
                        Spacer()
                        trafficLights
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 6) {
            dot(.red)
            dot(.yellow)
            dot(.green)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color.opacity(0.95))
            .frame(width: 11, height: 11)
            .overlay(
                Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
            )
    }

    private var killDot: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.65))
                .frame(width: 16, height: 16)
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

