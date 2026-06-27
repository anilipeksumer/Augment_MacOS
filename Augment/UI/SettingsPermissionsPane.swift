import AppKit
import SwiftUI

// MARK: - Permissions

struct PermissionsSettingsPane: View {
    @EnvironmentObject private var preferences: SharedPreferences
    @EnvironmentObject private var permissions: PermissionCoordinator

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    title: Localizer.string("permissions.title"),
                    subtitle: Localizer.string("permissions.subtitle"),
                    systemImage: "lock.shield.fill",
                    tint: .accentColor
                )
            }

            Section {
                HStack(alignment: .top, spacing: 14) {
                    statusBadge
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(statusDetail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                HStack {
                    Button {
                        permissions.refresh()
                    } label: {
                        Label(Localizer.string("permissions.recheck"), systemImage: "arrow.clockwise")
                    }

                    Button {
                        permissions.requestAccessAndBeginPolling(force: true)
                    } label: {
                        Label(Localizer.string("permissions.reprompt"), systemImage: "bell.fill")
                    }
                    .disabled(permissions.state == .granted)

                    Spacer()

                    Button {
                        permissions.openSystemSettings()
                    } label: {
                        Label(Localizer.string("permissions.settings"), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text(Localizer.string("permissions.status"))
            } footer: {
                Text(Localizer.string("permissions.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            if permissions.state != .granted {
                permissions.requestAccessAndBeginPolling(force: false)
            }
        }
    }

    private var statusBadge: some View {
        ZStack {
            Circle()
                .fill(badgeColor.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: badgeIcon)
                .foregroundStyle(badgeColor)
                .font(.system(size: 16, weight: .semibold))
        }
    }

    private var badgeColor: Color {
        switch permissions.state {
        case .granted: return .green
        case .denied, .unknown: return .orange
        }
    }

    private var badgeIcon: String {
        switch permissions.state {
        case .granted: return "checkmark"
        case .denied, .unknown: return "exclamationmark"
        }
    }

    private var statusTitle: String {
        switch permissions.state {
        case .granted: return Localizer.string("permissions.enabled")
        case .denied, .unknown: return Localizer.string("permissions.required")
        }
    }

    private var statusDetail: String {
        switch permissions.state {
        case .granted:
            return Localizer.string("permissions.desc_enabled")
        case .denied, .unknown:
            return Localizer.string("permissions.desc_required")
        }
    }
}
