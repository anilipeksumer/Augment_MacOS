import AppKit
import SwiftUI

// MARK: - Hover

struct HoverSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Group {

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(Localizer.string("hover.delay"))
                        Spacer()
                        Text(formattedDelay)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $preferences.hoverOpenDelay,
                        in: SharedPreferences.hoverDelayRange,
                        step: 0.05
                    ) {
                        Text(Localizer.string("hover.delay"))
                    } minimumValueLabel: {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Image(systemName: "tortoise.fill")
                            .foregroundStyle(.secondary)
                    }
                    .labelsHidden()
                    Text(Localizer.string("hover.delay_desc"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text(Localizer.string("hover.timing"))
            }

            Section {
                Picker(Localizer.string("hover.size"), selection: $preferences.previewSize) {
                    ForEach(PreviewPanelSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .pickerStyle(.segmented)

                ToggleRow(
                    title: Localizer.string("hover.suppress"),
                    subtitle: Localizer.string("hover.suppress_desc"),
                    systemImage: "eye.slash.fill",
                    tint: .gray,
                    isOn: $preferences.suppressEmptyPreviews
                )
                ToggleRow(
                    title: Localizer.string("hover.header_actions"),
                    subtitle: Localizer.string("hover.header_actions_desc"),
                    systemImage: "rectangle.compress.vertical",
                    tint: .teal,
                    isOn: $preferences.headerActionsEnabled
                )
                ToggleRow(
                    title: Localizer.string("hover.magnify"),
                    subtitle: Localizer.string("hover.magnify_desc"),
                    systemImage: "rectangle.expand.vertical",
                    tint: .purple,
                    isOn: $preferences.spaceMagnifyEnabled
                )
            } header: {
                Text(Localizer.string("hover.appearance"))
            }

            Section {
                ToggleRow(
                    title: Localizer.string("hover.middle_click"),
                    subtitle: Localizer.string("hover.middle_click_desc"),
                    systemImage: "computermouse.fill",
                    tint: .red,
                    isOn: $preferences.middleClickCloseEnabled
                )
                ToggleRow(
                    title: Localizer.string("hover.drag_out"),
                    subtitle: Localizer.string("hover.drag_out_desc"),
                    systemImage: "hand.draw.fill",
                    tint: .mint,
                    isOn: $preferences.dragOutEnabled
                )
            } header: {
                Text(Localizer.string("hover.interactions"))
            }
        }
    }

    private var formattedDelay: String {
        let value = preferences.hoverOpenDelay
        if value <= 0.001 { return Localizer.string("hover.instant") }
        return String(format: "%.2fs", value)
    }
}
