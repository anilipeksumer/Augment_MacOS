import AppKit
import SwiftUI

// MARK: - Dock Click

struct DockClickSettingsPane: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: Localizer.string("dock_click.title"),
                    subtitle: Localizer.string("dock_click.subtitle"),
                    systemImage: "cursorarrow.click.2",
                    tint: .indigo
                )
            }

            Section {
                ToggleRow(
                    title: Localizer.string("dock_click.toggle_minimize"),
                    subtitle: Localizer.string("dock_click.toggle_minimize_desc"),
                    systemImage: "rectangle.compress.vertical",
                    tint: .indigo,
                    isOn: $preferences.dockClickBehaviorEnabled
                )
            } header: {
                Text(Localizer.string("dock_click.behavior"))
            }

            Section {
                Picker(Localizer.string("dock_click.effect_picker"), selection: $preferences.minimizeEffect) {
                    ForEach(DockMinimizeEffect.allCases) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                .pickerStyle(.segmented)

                Text(preferences.minimizeEffect.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(Localizer.string("dock_click.effect_desc"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text(Localizer.string("dock_click.effect_title"))
            }
        }
        .formStyle(.grouped)
    }
}

