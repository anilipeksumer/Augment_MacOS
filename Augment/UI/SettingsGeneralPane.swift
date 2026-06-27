import AppKit
import SwiftUI

// MARK: - General

struct GeneralSettingsPane: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: Localizer.string("general.title"),
                    subtitle: Localizer.string("general.subtitle"),
                    systemImage: "sparkles",
                    tint: .accentColor
                )
            }

            Section {
                ToggleRow(
                    title: Localizer.string("feature.hover_title"),
                    subtitle: Localizer.string("feature.hover_subtitle"),
                    systemImage: "rectangle.stack",
                    tint: .blue,
                    isOn: $preferences.windowPreviewsEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.dockClick_title"),
                    subtitle: Localizer.string("feature.dockClick_subtitle"),
                    systemImage: "cursorarrow.click.2",
                    tint: .indigo,
                    isOn: $preferences.dockClickBehaviorEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.windowControls_title"),
                    subtitle: Localizer.string("feature.windowControls_subtitle"),
                    systemImage: "macwindow.on.rectangle",
                    tint: .green,
                    isOn: $preferences.trafficLightEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.folderQL_title"),
                    subtitle: Localizer.string("feature.folderQL_subtitle"),
                    systemImage: "folder.fill",
                    tint: .orange,
                    isOn: $preferences.folderQuickLookEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.finderMenu_title"),
                    subtitle: Localizer.string("feature.finderMenu_subtitle"),
                    systemImage: "doc.badge.plus",
                    tint: .green,
                    isOn: $preferences.finderNewFileMenuEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.displays_title"),
                    subtitle: Localizer.string("feature.displays_subtitle"),
                    systemImage: "rectangle.inset.filled.and.person.filled",
                    tint: .pink,
                    isOn: $preferences.dockLockEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.snapping_title"),
                    subtitle: Localizer.string("feature.snapping_subtitle"),
                    systemImage: "rectangle.split.2x1.fill",
                    tint: .cyan,
                    isOn: $preferences.windowSnappingEnabled
                )
                ToggleRow(
                    title: Localizer.string("feature.notch_title"),
                    subtitle: Localizer.string("feature.notch_subtitle"),
                    systemImage: "platter.filled.top.iphone",
                    tint: .purple,
                    isOn: $preferences.notchEnabled
                )
            } header: {
                Text(Localizer.string("general.features"))
            }

            Section {
                Picker(Localizer.string("general.language"), selection: $preferences.appLanguage) {
                    Text(Localizer.string("general.lang_system")).tag("system")
                    Text(Localizer.string("general.lang_en")).tag("en")
                    Text(Localizer.string("general.lang_tr")).tag("tr")
                }
                .pickerStyle(.menu)
            } header: {
                Text(Localizer.string("general.language"))
            }

            Section {
                LabeledContent(Localizer.string("general.version")) {
                    Text(Self.appVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent(Localizer.string("general.build")) {
                    Text(Self.buildNumber)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text(Localizer.string("general.about"))
            }
        }
        .formStyle(.grouped)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
