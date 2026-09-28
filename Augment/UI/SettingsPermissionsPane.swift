import AppKit
import SwiftUI

// MARK: - Permissions

/// Every permission Augment can use, its live status, and which features
/// depend on it. Nothing here is requested until the user asks.
struct PermissionsSettingsPane: View {
    private struct Row: Identifiable {
        let permission: FeaturePermission
        let usedBy: [String]
        var id: String { permission.title }
    }

    private var rows: [Row] {
        [
            Row(permission: .accessibility, usedBy: [
                Localizer.string("feature.hover_title"), Localizer.string("feature.dockClick_title"),
                Localizer.string("feature.snapping_title"), Localizer.string("snaplayouts.title"),
                Localizer.string("switcher.title"), Localizer.string("cutpaste.window_title"),
                Localizer.string("cutpaste.file_title"),
            ]),
            Row(permission: .screenRecording, usedBy: [
                Localizer.string("feature.hover_title"), Localizer.string("switcher.title"),
            ]),
            Row(permission: .finderAutomation, usedBy: [
                Localizer.string("cutpaste.file_title"),
            ]),
        ]
    }

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: Localizer.string("permissions.title"),
                    subtitle: Localizer.string("permissions.subtitle_v2"),
                    systemImage: "lock.shield.fill",
                    tint: .orange
                )
            }

            Section {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            let granted = row.permission.isGranted
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                                    .font(.system(size: 18))
                                    .foregroundStyle(granted ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.permission.title).font(.body.weight(.medium))
                                    Text(String(format: Localizer.string("perm.used_by"), row.usedBy.joined(separator: ", ")))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 12)
                                if granted {
                                    Text(Localizer.string("perm.granted")).font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button(Localizer.string("perm.grant")) { row.permission.request() }
                                        .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 8)
                            if row.id != rows.last?.id { Divider() }
                        }
                    }
                }
            } footer: {
                Text(Localizer.string("permissions.footer_v2"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
