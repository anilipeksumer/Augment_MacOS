import AppKit
import SwiftUI

// MARK: - Dock Click

struct DockClickSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Group {

            Section {
                ToggleRow(
                    title: Localizer.string("dock_click.toggle_minimize"),
                    subtitle: Localizer.string("dock_click.toggle_minimize_desc"),
                    systemImage: "rectangle.compress.vertical",
                    tint: .indigo,
                    isOn: $preferences.dockClickBehaviorEnabled,
                    requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.dockClickBehaviorEnabled)
                )
            } header: {
                Text(Localizer.string("dock_click.behavior"))
            }

        }
    }
}

