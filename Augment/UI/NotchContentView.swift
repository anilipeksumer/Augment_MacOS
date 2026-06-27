import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    let notchRect: CGRect
    let hasNotch: Bool
    
    
    @State private var hoverTask: Task<Void, Never>?
    @State private var isDraggingOver = false
    @State private var pulseScale: CGFloat = 1.0

    private var expandedHeight: CGFloat {
        if isDraggingOver && !viewModel.isExpanded {
            var h: CGFloat = 38
            h += 12
            h += 75 + 16
            return h
        }
        
        var h: CGFloat = 38
        var hasContent = false
        
        if viewModel.showMusic {
            h += 12
            var mediaHeight: CGFloat = 60
            if let info = viewModel.mediaInfo {
                var textAndControlsHeight: CGFloat = 31
                if let duration = info.duration, duration > 0 {
                    textAndControlsHeight += 18
                }
                if viewModel.mediaControlsEnabled {
                    textAndControlsHeight += 34
                }
                mediaHeight = max(mediaHeight, textAndControlsHeight)
            } else {
                mediaHeight = 60
            }
            mediaHeight += 16
            h += mediaHeight
            hasContent = true
        }
        
        if viewModel.showShelf {
            h += 12
            h += 75 + 16
            hasContent = true
        }
        
        if !hasContent {
            h += 14
        }
        
        return h
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // The actual visual pill
                RoundedRectangle(
                    cornerRadius: (viewModel.isExpanded || isDraggingOver) ? 28 : notchRect.height / 2,
                    style: .continuous
                )
                .fill(Color.black.opacity((!viewModel.isExpanded && !isDraggingOver && hasNotch) ? 0 : 1))
                .overlay(
                    Group {
                        if isDraggingOver {
                            RoundedRectangle(
                                cornerRadius: 28,
                                style: .continuous
                            )
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.blue, Color.purple, Color.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 2
                            )
                            .opacity(pulseScale)
                            .onAppear {
                                withAnimation(Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                    pulseScale = 0.3
                                }
                            }
                            .onDisappear {
                                pulseScale = 1.0
                            }
                        }
                    }
                )
                .shadow(color: .black.opacity((viewModel.isExpanded || isDraggingOver) ? 0.4 : 0), radius: 12, y: 8)
                .frame(width: (viewModel.isExpanded || isDraggingOver) ? 400 : notchRect.width)
                
                if viewModel.isExpanded || isDraggingOver {
                    expandedLayout
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        .frame(width: 400)
                }
            }
            // The hit area for hover is slightly wider than the notch for reliability
            .frame(
                width: (viewModel.isExpanded || isDraggingOver) ? 400 : notchRect.width + 60,
                height: (viewModel.isExpanded || isDraggingOver) ? expandedHeight : notchRect.height
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                DispatchQueue.main.async {
                    handleHover(hovering)
                }
            }
            .onDrop(of: ["public.file-url"], isTargeted: $isDraggingOver) { providers in
                let pendingProviders = providers
                DispatchQueue.main.async {
                    _ = handleDrop(pendingProviders)
                }
                return true
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            hoverTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(viewModel.hoverDelay * 1_000_000_000))
                if !Task.isCancelled {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        viewModel.isExpanded = true
                    }
                }
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                viewModel.isExpanded = false
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    var url: URL?
                    if let nsUrl = item as? NSURL {
                        url = nsUrl as URL
                    } else if let nsData = item as? Data {
                        url = URL(dataRepresentation: nsData, relativeTo: nil)
                    } else if let pathString = item as? String {
                        url = URL(fileURLWithPath: pathString)
                    }
                    
                    if let resolvedUrl = url {
                        DispatchQueue.main.async {
                            viewModel.addShelfItem(url: resolvedUrl)
                        }
                    }
                }
            }
        }
        return true
    }

    private var expandedLayout: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack(spacing: 0) {
                if viewModel.calendarEnabled {
                    calendarWidget
                }
                Spacer()
                if viewModel.showBattery {
                    appleBatteryWidget
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            
            // Media
            if viewModel.showMusic {
                Spacer(minLength: 12)
                MediaWidget(viewModel: viewModel)
                    .padding(.horizontal, 24)
            }

            // Shelf
            if viewModel.showShelf {
                Spacer(minLength: 12)
                enhancedShelfWidget
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var appleBatteryWidget: some View {
        switch viewModel.batteryStyle {
        case "symbol":
            HStack(spacing: 6) {
                Image(systemName: batterySymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(batteryColor(viewModel.battery))
                Text("\(viewModel.battery?.level ?? 0)%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        case "percent":
            HStack(spacing: 4) {
                if viewModel.battery?.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.green)
                }
                Text("\(viewModel.battery?.level ?? 0)%")
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(batteryColor(viewModel.battery))
            }
        default:
            batteryGauge
        }
    }

    private var batteryGauge: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.battery?.level ?? 0)%")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 40, alignment: .trailing)
            
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 28, height: 14)
                
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(batteryColor(viewModel.battery))
                    .frame(width: CGFloat(max(2, viewModel.battery?.level ?? 0)) / 100 * 24, height: 10)
                    .padding(.leading, 2)
                
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 2, height: 6)
                    .offset(x: 29.5)
            }
            
            if viewModel.battery?.isCharging == true {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        }
    }

    private var batterySymbol: String {
        let level = viewModel.battery?.level ?? 0
        if viewModel.battery?.isCharging == true { return "battery.100percent.bolt" }
        if level >= 88 { return "battery.100percent" }
        if level >= 63 { return "battery.75percent" }
        if level >= 38 { return "battery.50percent" }
        if level >= 13 { return "battery.25percent" }
        return "battery.0percent"
    }

    private func batteryColor(_ info: BatteryInfo?) -> Color {
        guard let info = info else { return .gray }
        if info.isCharging { return .green }
        if info.level < 20 { return .red }
        if info.level < 40 { return .orange }
        return .green
    }

    @ViewBuilder
    private var calendarWidget: some View {
        switch viewModel.calendarStyle {
        case "badge":
            VStack(spacing: 0) {
                Text(localizedDate(.dateTime.month(.abbreviated)))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .textCase(.uppercase)
                    .frame(width: 34, height: 13)
                    .background(Color.red)
                Text(localizedDate(.dateTime.day()))
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(.black)
                    .frame(width: 34, height: 24)
                    .background(Color.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case "text":
            VStack(alignment: .leading, spacing: 1) {
                Text(localizedDate(.dateTime.weekday(.wide)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(viewModel.currentDate.formatted(
                    .dateTime.month(.wide).day().locale(Localizer.currentLocale)
                ))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        default:
            compactCalendar
        }
    }

    private var compactCalendar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: -2) {
                Text(localizedDate(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.red)
                    .textCase(.uppercase)
                Text(localizedDate(.dateTime.day()))
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
            }
            Text(localizedDate(.dateTime.month(.wide)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private func localizedDate(_ style: Date.FormatStyle) -> String {
        viewModel.currentDate.formatted(style.locale(Localizer.currentLocale))
    }



    private var enhancedShelfWidget: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(isDraggingOver ? 0.18 : 0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isDraggingOver ? Color.accentColor : Color.white.opacity(0.06),
                            style: StrokeStyle(
                                lineWidth: isDraggingOver ? 2 : 1,
                                dash: isDraggingOver ? [7, 5] : []
                            )
                        )
                )
            
            if viewModel.shelfItems.isEmpty {
                Label(Localizer.string("notch.drop_files"), systemImage: "tray.and.arrow.down").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(viewModel.shelfItems) { item in
                            VStack(spacing: 6) {
                                if let icon = item.icon { Image(nsImage: icon).resizable().frame(width: 36, height: 36) }
                                Text(item.name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).frame(width: 65)
                            }
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
                            .onDrag {
                                NSItemProvider(object: item.url as NSURL)
                            }
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.pointingHand.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            }
                            .contextMenu {
                                Button(Localizer.string("notch.open")) { NSWorkspace.shared.open(item.url) }
                                Button(Localizer.string("notch.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button(Localizer.string("notch.copy")) { viewModel.copyToClipboard(item) }
                                Divider()
                                Button(Localizer.string("notch.remove"), role: .destructive) { viewModel.removeShelfItem(item) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            if isDraggingOver {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.black.opacity(0.72))
                Label(Localizer.string("notch.drop_here"), systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(0.94 + pulseScale * 0.08)
            }
        }
        .frame(height: 75)
        .animation(.easeOut(duration: 0.18), value: isDraggingOver)
    }
}
