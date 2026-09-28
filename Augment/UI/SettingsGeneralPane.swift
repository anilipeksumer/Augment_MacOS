import AppKit
import ServiceManagement
import SwiftUI

// MARK: - General

/// The app itself: which features are on (with a jump to their page),
/// launch at login, language and version. Feature switches live on their
/// own pages only, so no setting appears twice.
struct GeneralSettingsPane: View {
    @EnvironmentObject private var preferences: SharedPreferences
    var open: (SettingsTab) -> Void = { _ in }

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// One settings page and the switches that live on it.
    private struct PageSummary: Identifiable {
        let tab: SettingsTab
        let features: [(name: String, isOn: Bool)]
        var id: SettingsTab { tab }
        var onCount: Int { features.filter(\.isOn).count }
    }

    private var pages: [PageSummary] {
        [
            PageSummary(tab: .dock, features: [
                (Localizer.string("short.previews"), preferences.windowPreviewsEnabled),
                (Localizer.string("short.dockclick"), preferences.dockClickBehaviorEnabled),
                (Localizer.string("short.docklock"), preferences.dockLockEnabled),
            ]),
            PageSummary(tab: .windows, features: [
                (Localizer.string("short.snap"), preferences.windowSnappingEnabled),
                (Localizer.string("short.layouts"), preferences.snapLayoutsEnabled),
                (Localizer.string("short.switcher"), preferences.windowSwitcherEnabled),
            ]),
            PageSummary(tab: .finder, features: [
                (Localizer.string("short.newfile"), preferences.finderNewFileMenuEnabled),
                (Localizer.string("short.folderql"), preferences.folderQuickLookEnabled),
                (Localizer.string("short.filecut"), preferences.fileCutPasteEnabled),
            ]),
            PageSummary(tab: .notch, features: [
                (Localizer.string("short.notch"), preferences.notchEnabled),
            ]),
            PageSummary(tab: .sound, features: [
                (Localizer.string("short.mixer"), preferences.volumeMixerEnabled),
            ]),
        ]
    }

    private var enabledCount: Int { pages.reduce(0) { $0 + $1.onCount } }
    private var totalCount: Int { pages.reduce(0) { $0 + $1.features.count } }

    private var missingPermissions: [FeaturePermission] {
        [.accessibility, .screenRecording, .finderAutomation].filter { !$0.isGranted }
    }

    var body: some View {
        Form {
            // App identity instead of a generic gear header.
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: AugmentApplicationIcon.load() ?? NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Augment").font(.title2.weight(.semibold))
                        Text(String(format: Localizer.string("general.summary"), enabledCount, totalCount))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("\(Localizer.string("about.version")) \(Self.appVersion) (\(Self.buildNumber))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(pages) { page in
                    Button { open(page.tab) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: page.tab.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(page.tab.tintColor.gradient))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.tab.title).foregroundStyle(.primary)
                                Text(summary(of: page))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text("\(page.onCount)/\(page.features.count)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(page.onCount > 0 ? .primary : .secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(Localizer.string("general.features"))
            }

            Section {
                Button { open(.permissions) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: missingPermissions.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(missingPermissions.isEmpty ? .green : .orange)
                            .frame(width: 26)
                        Text(missingPermissions.isEmpty
                             ? Localizer.string("general.perms_ok")
                             : String(format: Localizer.string("general.perms_missing"), missingPermissions.count))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text(Localizer.string("permissions.title"))
            }

            Section {
                Toggle(Localizer.string("general.launch_at_login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("Augment: launch at login change failed: %@", error.localizedDescription)
                        }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                ))
                Picker(Localizer.string("general.language"), selection: $preferences.appLanguage) {
                    Text(Localizer.string("general.lang_system")).tag("system")
                    Text(Localizer.string("general.lang_en")).tag("en")
                    Text(Localizer.string("general.lang_tr")).tag("tr")
                }
                .pickerStyle(.menu)
            } header: {
                Text(Localizer.string("general.app"))
            }
        }
        .formStyle(.grouped)
    }

    /// "Dock previews, Click to minimize" — or "All off".
    private func summary(of page: PageSummary) -> String {
        if page.features.count == 1 {
            return Localizer.string(page.onCount == 1 ? "general.on" : "general.all_off")
        }
        let on = page.features.filter(\.isOn).map(\.name)
        return on.isEmpty ? Localizer.string("general.all_off") : on.joined(separator: ", ")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
