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
        HStack(spacing: 16) {
            // Album art with App icon overlay
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    
                    if viewModel.showAlbumArt, let art = viewModel.mediaInfo?.albumArt {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.15))
                    }
                }
                .frame(width: 60, height: 60)
                .scaleEffect(isHoveringArt ? 1.05 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHoveringArt)
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
            
            // Metadata & Progress & Controls
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        // Title
                        Text(viewModel.mediaInfo?.title ?? "No Media")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        
                        // Artist
                        Text(viewModel.mediaInfo?.artist ?? (viewModel.mediaInfo?.appName ?? "Ready"))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    if viewModel.availableSources.count > 1 {
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
                                if hovering {
                                    NSCursor.pointingHand.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
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
                                if hovering {
                                    NSCursor.pointingHand.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            }
                        }
                    } else {
                        // Small App Name label if not showing app icon
                        if !viewModel.showAppIcon, let appName = viewModel.mediaInfo?.appName {
                            Text(appName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                        }
                    }
                }
                
                // Progress Bar
                if let duration = viewModel.mediaInfo?.duration, duration > 0 {
                    let progress = min(1.0, max(0.0, localElapsedTime / duration))
                    
                    VStack(spacing: 3) {
                        // Progress track
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.12))
                                
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: geo.size.width * CGFloat(progress))
                            }
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
                                if hovering {
                                    NSCursor.pointingHand.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            }
                        }
                        .frame(height: isHoveringProgress ? 6 : 4)
                        .animation(.easeOut(duration: 0.15), value: isHoveringProgress)
                        
                        // Time labels
                        HStack {
                            Text(formatTime(localElapsedTime))
                            Spacer()
                            Text(formatTime(duration))
                        }
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // Controls Row
                if viewModel.mediaControlsEnabled && viewModel.mediaInfo != nil {
                    HStack(spacing: 16) {
                        Spacer()
                        
                        // Previous
                        Button {
                            viewModel.mediaCommand("previous track")
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(isHoveringPrev ? .white : .white.opacity(0.7))
                                .scaleEffect(isHoveringPrev ? 1.1 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringPrev = $0 }
                        
                        // Seek Backward
                        Button {
                            viewModel.mediaCommand("seek_backward")
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 13))
                                .foregroundStyle(isHoveringSeekPrev ? .white : .white.opacity(0.7))
                                .scaleEffect(isHoveringSeekPrev ? 1.1 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringSeekPrev = $0 }
                        
                        // Play / Pause
                        Button {
                            viewModel.mediaCommand("playpause")
                        } label: {
                            Image(systemName: (viewModel.mediaInfo?.isPlaying == true) ? "pause.fill" : "play.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(isHoveringPlay ? .white : .white.opacity(0.85))
                                .frame(width: 32, height: 32)
                                .background(
                                    Circle()
                                        .fill(Color.white.opacity(isHoveringPlay ? 0.15 : 0.08))
                                )
                                .scaleEffect(isHoveringPlay ? 1.05 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringPlay = $0 }
                        
                        // Seek Forward
                        Button {
                            viewModel.mediaCommand("seek_forward")
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 13))
                                .foregroundStyle(isHoveringSeekNext ? .white : .white.opacity(0.7))
                                .scaleEffect(isHoveringSeekNext ? 1.1 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringSeekNext = $0 }
                        
                        // Next
                        Button {
                            viewModel.mediaCommand("next track")
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(isHoveringNext ? .white : .white.opacity(0.7))
                                .scaleEffect(isHoveringNext ? 1.1 : 1.0)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringNext = $0 }
                        
                        Spacer()
                    }
                    .padding(.top, 2)
                    .disabled(viewModel.mediaCommandInFlight)
                    .opacity(viewModel.mediaCommandInFlight ? 0.55 : 1)
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
