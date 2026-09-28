import Combine
import SwiftUI

struct MediaWidget: View {
    @ObservedObject var viewModel: NotchViewModel

    @State private var isHoveringPlay = false
    @State private var isHoveringNext = false
    @State private var isHoveringPrev = false
    @State private var isHoveringSeekPrev = false
    @State private var isHoveringSeekNext = false
    @State private var isHoveringArt = false
    @State private var isHoveringProgress = false

    // Timer to locally interpolate elapsed time so we don't have to poll too aggressively
    @State private var localElapsedTime: Double = 0
    let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 14) {
            albumArt

            // Metadata & Progress & Controls
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(
                            text: viewModel.mediaInfo?.title ?? "No Media",
                            font: .system(size: 14, weight: .semibold),
                            color: .white
                        )

                        MarqueeText(
                            text: viewModel.mediaInfo?.artist ?? (viewModel.mediaInfo?.appName ?? "Ready"),
                            font: .system(size: 11, weight: .regular),
                            color: .white.opacity(0.6)
                        )
                    }

                    Spacer(minLength: 8)

                    if viewModel.availableSources.count > 1 {
                        sourceSwitcher
                    } else if !viewModel.showAppIcon, let appName = viewModel.mediaInfo?.appName {
                        Text(appName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }

                if let duration = viewModel.mediaInfo?.duration, duration > 0 {
                    progressBar(duration: duration)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if viewModel.mediaControlsEnabled && viewModel.mediaInfo != nil {
                    controlsRow
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 8)
        .onReceive(timer) { _ in
            if viewModel.isExpanded, viewModel.mediaInfo?.isPlaying == true {
                updateLocalProgress()
            }
        }
        .onAppear {
            if let elapsed = viewModel.mediaInfo?.elapsedTime {
                localElapsedTime = elapsed
            }
        }
        .onChange(of: viewModel.mediaInfo?.elapsedTime) { newElapsed in
            if let newElapsed {
                localElapsedTime = newElapsed
            }
        }
        .onChange(of: viewModel.activeSourceIndex) { _ in
            localElapsedTime = viewModel.mediaInfo?.elapsedTime ?? 0
        }
    }

    // MARK: - Album art

    private var albumArt: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.white.opacity(0.08))

                if viewModel.showAlbumArt, let art = viewModel.mediaInfo?.albumArt {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.15))
                }
            }
            .frame(width: 72, height: 72)
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(
                color: (viewModel.mediaInfo?.isPlaying == true)
                    ? viewModel.ambientColor.opacity(0.55) : .black.opacity(0.3),
                radius: (viewModel.mediaInfo?.isPlaying == true) ? 14 : 8, x: 0, y: 4
            )
            .scaleEffect(isHoveringArt ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringArt)
            .animation(.easeInOut(duration: 0.5), value: viewModel.ambientColor)
            .onHover { hovering in
                isHoveringArt = hovering
            }

            if viewModel.showAppIcon, let icon = viewModel.mediaInfo?.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color.black)
                            .padding(-2)
                    )
                    .offset(x: 4, y: 4)
            }
        }
    }

    // MARK: - Source switcher

    private var sourceSwitcher: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.cycleMediaSource(forward: false)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }

            Menu {
                ForEach(Array(viewModel.availableSources.enumerated()), id: \.offset) { index, source in
                    Button {
                        viewModel.selectMediaSource(index: index)
                    } label: {
                        Label(
                            "\(source.appName): \(source.title)",
                            systemImage: index == viewModel.activeSourceIndex ? "checkmark.circle.fill" : "circle"
                        )
                    }
                }
            } label: {
                Text("\(viewModel.activeSourceIndex + 1)/\(viewModel.availableSources.count)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)

            Button {
                viewModel.cycleMediaSource(forward: true)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }

    // MARK: - Progress

    private func progressBar(duration: Double) -> some View {
        let progress = min(1.0, max(0.0, localElapsedTime / duration))

        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [viewModel.ambientColor, viewModel.ambientColor.opacity(0.6)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(progress))
                }
                // Thicken visually on hover without changing layout — a
                // growing frame pushed the row below and made the hover
                // area flicker as the pointer moved up and down.
                .frame(height: 4)
                .scaleEffect(y: isHoveringProgress ? 1.6 : 1, anchor: .center)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let width = geo.size.width
                            guard width > 0 else { return }
                            let pct = min(1.0, max(0.0, value.location.x / width))
                            localElapsedTime = duration * pct
                        }
                        .onEnded { value in
                            let width = geo.size.width
                            guard width > 0 else { return }
                            let pct = min(1.0, max(0.0, value.location.x / width))
                            let targetTime = duration * pct
                            viewModel.seekToTime(targetTime)
                        }
                )
                .allowsHitTesting(!viewModel.mediaCommandInFlight)
                .onHover { hovering in
                    isHoveringProgress = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
            }
            .frame(height: 10)
            .animation(.easeOut(duration: 0.15), value: isHoveringProgress)
            .animation(.easeInOut(duration: 0.5), value: viewModel.ambientColor)

            HStack {
                Text(formatTime(localElapsedTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 18) {
            Spacer()

            controlButton(system: "backward.fill", size: 14, isHovering: $isHoveringPrev) {
                viewModel.mediaCommand("previous track")
            }
            controlButton(system: "gobackward.10", size: 13, isHovering: $isHoveringSeekPrev) {
                viewModel.mediaCommand("seek_backward")
            }

            Button {
                viewModel.mediaCommand("playpause")
            } label: {
                Image(systemName: (viewModel.mediaInfo?.isPlaying == true) ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(isHoveringPlay ? viewModel.ambientColor.opacity(0.9) : viewModel.ambientColor.opacity(0.7))
                    )
                    .scaleEffect(isHoveringPlay ? 1.06 : 1.0)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringPlay = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHoveringPlay)
            .animation(.easeInOut(duration: 0.5), value: viewModel.ambientColor)

            controlButton(system: "goforward.10", size: 13, isHovering: $isHoveringSeekNext) {
                viewModel.mediaCommand("seek_forward")
            }
            controlButton(system: "forward.fill", size: 14, isHovering: $isHoveringNext) {
                viewModel.mediaCommand("next track")
            }

            Spacer()
        }
        .disabled(viewModel.mediaCommandInFlight)
        .opacity(viewModel.mediaCommandInFlight ? 0.55 : 1)
    }

    private func controlButton(
        system: String, size: CGFloat, isHovering: Binding<Bool>, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size))
                .foregroundStyle(isHovering.wrappedValue ? .white : .white.opacity(0.7))
                .scaleEffect(isHovering.wrappedValue ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovering.wrappedValue = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isHovering.wrappedValue)
    }

    private func updateLocalProgress() {
        guard let info = viewModel.mediaInfo else { return }
        if info.isPlaying {
            if let dur = info.duration {
                localElapsedTime = min(dur, localElapsedTime + 1.0)
            }
        } else {
            if let elapsed = info.elapsedTime {
                localElapsedTime = elapsed
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
