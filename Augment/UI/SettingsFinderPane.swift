import AppKit
import SwiftUI

// MARK: - Finder

struct FinderSettingsPane: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: Localizer.string("finder.title"),
                    subtitle: Localizer.string("finder.subtitle"),
                    systemImage: "folder.fill.badge.plus",
                    tint: .green
                )
            }

            Section {
                ToggleRow(
                    title: Localizer.string("finder.menu"),
                    subtitle: Localizer.string("finder.menu_desc"),
                    systemImage: "doc.badge.plus",
                    tint: .green,
                    isOn: $preferences.finderNewFileMenuEnabled
                )

                ToggleRow(
                    title: Localizer.string("finder.folder_ql"),
                    subtitle: Localizer.string("finder.folder_ql_desc"),
                    systemImage: "list.bullet.indent",
                    tint: .orange,
                    isOn: $preferences.folderQuickLookEnabled
                )

                ToggleRow(
                    title: Localizer.string("finder.warning"),
                    subtitle: Localizer.string("finder.warning_desc"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    isOn: $preferences.folderQuickLookShowWarning
                )
                .disabled(!preferences.folderQuickLookEnabled)
            } header: {
                Text(Localizer.string("finder.behavior"))
            } footer: {
                Text(Localizer.string("finder.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

