import AppKit
import SwiftUI

// MARK: - Finder

struct FinderSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Group {
            Section {
                Picker(Localizer.string("finder.shift_enter"), selection: $preferences.finderEnterBehavior) {
                    ForEach(FinderEnterBehavior.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(Localizer.string("finder.shift_enter_desc"))
                    .font(.caption).foregroundStyle(.secondary)
                if preferences.finderEnterBehavior != .system {
                    PermissionNotice(permissions: [.accessibility])
                }
            }

            Section {
                ToggleRow(title: Localizer.string("finder.backspace"),
                          subtitle: Localizer.string("finder.backspace_desc"),
                          systemImage: "delete.left", tint: .green,
                          isOn: $preferences.finderBackspaceEnabled,
                          requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.finderBackspaceEnabled))
                ToggleRow(title: Localizer.string("finder.double_click"),
                          subtitle: Localizer.string("finder.double_click_desc"),
                          systemImage: "cursorarrow.click.2", tint: .green,
                          isOn: $preferences.finderBlankDoubleClickEnabled,
                          requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.finderBlankDoubleClickEnabled))
                ToggleRow(title: Localizer.string("finder.middle_click"),
                          subtitle: Localizer.string("finder.middle_click_desc"),
                          systemImage: "computermouse", tint: .green,
                          isOn: $preferences.finderMiddleClickEnabled,
                          requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.finderMiddleClickEnabled))
                ToggleRow(title: Localizer.string("finder.paste_image"),
                          subtitle: Localizer.string("finder.paste_image_desc"),
                          systemImage: "photo.badge.plus", tint: .green,
                          isOn: $preferences.finderPasteImageEnabled,
                          requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.finderPasteImageEnabled))
                ToggleRow(title: Localizer.string("finder.f2"),
                          subtitle: Localizer.string("finder.f2_desc"),
                          systemImage: "character.cursor.ibeam", tint: .green,
                          isOn: $preferences.finderF2Enabled,
                          requires: FeatureRequirements.permissions(forPreferenceKey: AppGroupKey.finderF2Enabled))
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
    }
}

