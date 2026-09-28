import SwiftUI

// MARK: - Volume Mixer

struct VolumeMixerSettingsSections: View {
    @EnvironmentObject private var preferences: SharedPreferences

    var body: some View {
        Group {

            if #available(macOS 14.2, *) {
                Section {
                    ToggleRow(
                        title: Localizer.string("mixer.enable"),
                        subtitle: Localizer.string("mixer.enable_desc"),
                        systemImage: "speaker.wave.3.fill",
                        tint: .red,
                        isOn: $preferences.volumeMixerEnabled
                    )
                } header: {
                    Text(Localizer.string("mixer.toggle"))
                } footer: {
                    Text(Localizer.string("mixer.footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle(isOn: $preferences.pauseOnHeadphonesRemoved) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Localizer.string("mixer.pause_headphones"))
                            Text(Localizer.string("mixer.pause_headphones_desc")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                if preferences.volumeMixerEnabled {
                    Section {
                        MixerAppList()
                    } header: {
                        Text(Localizer.string("mixer.apps"))
                    }
                }
            } else {
                Section {
                    Label(Localizer.string("mixer.unsupported"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

@available(macOS 14.2, *)
private struct MixerAppList: View {
    @ObservedObject private var mixer = AudioProcessMixerService.shared

    var body: some View {
        if let error = mixer.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if mixer.apps.isEmpty {
            Text(Localizer.string("mixer.no_apps"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(mixer.apps) { app in
                HStack(spacing: 12) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                    }
                    Text(app.name)
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .opacity(app.isPlaying ? 1 : 0)

                    Button {
                        mixer.setMuted(!app.isMuted, forPID: app.id)
                    } label: {
                        Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .foregroundStyle(app.isMuted ? .red : .secondary)
                    }
                    .buttonStyle(.plain)

                    Slider(
                        value: Binding(
                            get: { app.volume },
                            set: { mixer.setVolume($0, forPID: app.id) }
                        ),
                        in: 0...1.5
                    )
                    Text("\(Int(app.volume * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Picker("", selection: Binding(
                        get: { app.outputDeviceUID ?? "" },
                        set: { mixer.setOutputDevice($0.isEmpty ? nil : $0, forPID: app.id) }
                    )) {
                        Text(Localizer.string("mixer.default_output")).tag("")
                        ForEach(mixer.outputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .help(Localizer.string("mixer.output_help"))
                }
                .padding(.vertical, 2)
            }
        }
    }
}
