import SwiftUI

/// Apple-styled instructional view that walks the user through granting
/// Accessibility access to Augment. The view auto-updates as the underlying
/// `PermissionCoordinator` transitions between states.
struct PermissionView: View {
    @ObservedObject var coordinator: PermissionCoordinator
    var onContinue: () -> Void

    @State private var heroAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            hero
            content
        }
        .frame(width: 520, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                heroAppeared = true
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                Image(systemName: iconName)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(iconColor)
                    .symbolRenderingMode(.hierarchical)
            }
            .scaleEffect(heroAppeared ? 1.0 : 0.85)
            .opacity(heroAppeared ? 1.0 : 0.0)

            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .opacity(heroAppeared ? 1.0 : 0.0)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .opacity(heroAppeared ? 1.0 : 0.0)
        }
        .padding(.top, 36)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Body

    private var content: some View {
        VStack(spacing: 18) {
            instructionList
            Spacer(minLength: 0)
            footerControls
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    private var instructionList: some View {
        VStack(alignment: .leading, spacing: 14) {
            instructionRow(number: 1,
                           title: "Open Privacy & Security",
                           detail: "Use the button below to jump straight to the Accessibility pane.")
            instructionRow(number: 2,
                           title: "Enable Augment",
                           detail: "Toggle the switch next to Augment in the Accessibility list.")
            instructionRow(number: 3,
                           title: "Return to Augment",
                           detail: "This window closes automatically as soon as access is granted.")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func instructionRow(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerControls: some View {
        HStack(spacing: 12) {
            Button(action: onContinue) {
                Label("Close", systemImage: "xmark")
                    .frame(minWidth: 72)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            
            if coordinator.isPolling {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for permission...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
            }

            Spacer()

            Button {
                if coordinator.state == .granted {
                    onContinue()
                } else {
                    coordinator.requestAccessAndBeginPolling(force: false)
                    coordinator.openSystemSettings()
                }
            } label: {
                Label(
                    coordinator.state == .granted ? "Done" : "Open System Settings",
                    systemImage: coordinator.state == .granted ? "checkmark" : "arrow.up.right.square"
                )
                .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - State-driven copy

    private var iconName: String {
        switch coordinator.state {
        case .granted: return "checkmark.shield.fill"
        case .denied, .unknown: return "lock.shield.fill"
        }
    }

    private var iconColor: Color {
        switch coordinator.state {
        case .granted: return .green
        case .denied, .unknown: return .accentColor
        }
    }

    private var title: String {
        switch coordinator.state {
        case .granted: return "All set"
        case .denied, .unknown: return "Augment needs Accessibility access"
        }
    }

    private var subtitle: String {
        switch coordinator.state {
        case .granted:
            return "Accessibility access is enabled. You can close this window."
        case .denied, .unknown:
            return "Augment uses Accessibility to read window positions, draw live previews and intercept Dock clicks – nothing leaves your Mac."
        }
    }
}
