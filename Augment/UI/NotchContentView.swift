import Quartz
import QuickLookThumbnailing
import SwiftUI

struct NotchContentView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var caffeinate = CaffeinateService.shared
    let notchRect: CGRect
    let hasNotch: Bool

    @State private var hoverTask: Task<Void, Never>?
    @State private var isDraggingOver = false
    @State private var pulseScale: CGFloat = 1.0
    @ObservedObject private var clipboardHistory = ClipboardHistoryService.shared
    @ObservedObject private var controls = SystemControlsService.shared
    @ObservedObject private var preview = ShelfPreview.shared

    private var isOpen: Bool { viewModel.isExpanded || isDraggingOver }
    private var isPlaying: Bool { viewModel.mediaInfo?.isPlaying == true }
    private let expandedWidth: CGFloat = 400
    private let expandedCornerRadius: CGFloat = 24

    private var expandedHeight: CGFloat {
        if isDraggingOver && !viewModel.isExpanded {
            return 38 + 12 + Self.tabCardHeight + 16
        }

        var h: CGFloat = 38
        var hasContent = false

        if viewModel.showMusic {
            h += 12
            var mediaHeight: CGFloat = 72
            if let info = viewModel.mediaInfo {
                var textAndControlsHeight: CGFloat = 34
                if let duration = info.duration, duration > 0 {
                    textAndControlsHeight += 20
                }
                if viewModel.mediaControlsEnabled {
                    textAndControlsHeight += 36
                }
                mediaHeight = max(mediaHeight, textAndControlsHeight)
            }
            mediaHeight += 16
            h += mediaHeight
            hasContent = true
        }

        if viewModel.nextMeeting != nil {
            h += 10 + Self.meetingRowHeight
        }

        if !availableTabs.isEmpty {
            h += 12 + Self.tabBarHeight + 8 + cardHeight
            hasContent = true
        }

        // Control row: brightness, volume, keep awake.
        h += 12 + Self.controlRowHeight + 16
        hasContent = true

        if !hasContent {
            h += 14
        }

        return h
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                notchShape
                    .fill(Color.black.opacity((!isOpen && hasNotch) ? 0 : 1))
                    .overlay(ambientWash)
                    .overlay(glassHighlight)
                    .overlay(dragOverlay)
                    .shadow(color: shadowColor, radius: isOpen ? 24 : 0, y: isOpen ? 10 : 0)
                    .frame(width: isOpen ? expandedWidth : notchRect.width)
                    .animation(.interpolatingSpring(stiffness: 340, damping: 30), value: isOpen)

                if !isOpen, let arrival = viewModel.screenshotArrival {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold))
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.mint)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: max(22, notchRect.height - 4))
                    .background(.black, in: Capsule())
                    .overlay(Capsule().strokeBorder(.mint.opacity(0.4), lineWidth: 1))
                    .shadow(color: .mint.opacity(0.25), radius: 5)
                    .offset(x: notchRect.width / 2 + 26, y: 2)
                    .id(arrival)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                    .allowsHitTesting(false)
                    .accessibilityLabel(Localizer.string("clip.screenshot"))
                }

                if isOpen {
                    expandedLayout
                        .frame(width: expandedWidth)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                        )
                }
            }
            // The hit area for hover is slightly wider than the notch for reliability
            .frame(
                width: isOpen ? expandedWidth : notchRect.width + 60,
                height: isOpen ? expandedHeight : notchRect.height
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                DispatchQueue.main.async {
                    handleHover(hovering)
                }
            }
            .coordinateSpace(name: "notchDrop")
            .onPreferenceChange(DropZoneFramesKey.self) { dropZoneFrames = $0 }
            .onDrop(of: [.fileURL], delegate: NotchDropDelegate(
                isTargeted: $isDraggingOver,
                hoveredZone: $hoveredZone,
                zones: dropZoneFrames,
                perform: { zone, providers in
                    DispatchQueue.main.async { _ = handleDrop(providers, zone: zone ?? .shelf) }
                }
            ))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(.interpolatingSpring(stiffness: 300, damping: 28), value: expandedHeight)
    }

    // MARK: - Shape & materials

    private var notchShape: some InsettableShape {
        RoundedRectangle(
            cornerRadius: isOpen ? expandedCornerRadius : notchRect.height / 2,
            style: .continuous
        )
    }

    /// A soft, low-opacity radial wash of the current artwork's ambient
    /// color — the same trick real "Now Playing" surfaces use so the panel
    /// never feels like a flat black rectangle.
    private var ambientWash: some View {
        Group {
            if isOpen && viewModel.showMusic && viewModel.mediaInfo != nil {
                notchShape
                    .fill(
                        RadialGradient(
                            colors: [viewModel.ambientColor.opacity(0.35), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 260
                        )
                    )
                    .blendMode(.plusLighter)
            }
        }
    }

    /// Thin inner top edge highlight, the way glassy macOS surfaces catch
    /// light along their top border.
    private var glassHighlight: some View {
        notchShape
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(isOpen ? 0.16 : 0), .white.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
    }

    @ViewBuilder
    private var dragOverlay: some View {
        if isDraggingOver {
            notchShape
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.blue, Color.purple, Color.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .opacity(0.9)
        }
    }

    private var shadowColor: Color {
        guard isOpen else { return .clear }
        if isPlaying && viewModel.showMusic {
            return viewModel.ambientColor.opacity(0.45)
        }
        return .black.opacity(0.45)
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            hoverTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(viewModel.hoverDelay * 1_000_000_000))
                if !Task.isCancelled {
                    withAnimation(.interpolatingSpring(stiffness: 340, damping: 30)) {
                        viewModel.isExpanded = true
                    }
                }
            }
        } else {
            withAnimation(.interpolatingSpring(stiffness: 340, damping: 32)) {
                viewModel.isExpanded = false
            }
        }
    }

    @State private var dropZoneFrames: [DropZone: CGRect] = [:]
    @State private var hoveredZone: DropZone?

    /// Collects the dropped file URLs, then sends them where the user let go:
    /// the shelf, AirDrop, or a zip archive added to the shelf.
    private func handleDrop(_ providers: [NSItemProvider], zone: DropZone) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            switch zone {
            case .shelf: urls.forEach { viewModel.addShelfItem(url: $0) }
            case .airdrop: ShelfActions.airDrop(urls)
            case .zip: ShelfActions.zip(urls) { archive in
                if let archive { viewModel.addShelfItem(url: archive) }
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

            if let meeting = viewModel.nextMeeting {
                meetingRow(meeting)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            // Media
            if viewModel.showMusic {
                Spacer(minLength: 12)
                MediaWidget(viewModel: viewModel)
                    .padding(.horizontal, 20)
            }

            // Files / clipboard / note share one card with a tab strip, so
            // the notch stays compact instead of stacking every widget.
            if !availableTabs.isEmpty {
                Spacer(minLength: 12)
                lowerTabs
                    .padding(.horizontal, 16)
            }

            Spacer(minLength: 12)
            controlRow
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Lower tabs

    static let meetingRowHeight: CGFloat = 40

    private func meetingRow(_ meeting: UpcomingEvent) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: meeting.color)).frame(width: 4, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(Self.meetingTime(meeting))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(viewModel.meetingIsAlert ? Color.orange : .white.opacity(0.55))
            }
            Spacer(minLength: 6)
            if let url = meeting.joinURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text(Localizer.string("meetings.join"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.meetingRowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(viewModel.meetingIsAlert ? 0.14 : 0.07)))
    }

    static func meetingTime(_ meeting: UpcomingEvent) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        let range = "\(f.string(from: meeting.start)) – \(f.string(from: meeting.end))"
        if meeting.isInProgress { return "\(Localizer.string("meetings.now")) · \(range)" }
        return "\(String(format: Localizer.string("meetings.in_minutes"), max(0, meeting.minutesUntilStart))) · \(range)"
    }

    static let tabBarHeight: CGFloat = 24
    static let tabCardHeight: CGFloat = 92
    static let mirrorCardHeight: CGFloat = 190

    private var cardHeight: CGFloat { currentTab == .mirror ? Self.mirrorCardHeight : Self.tabCardHeight }

    private func dropZone(_ zone: DropZone, title: String, icon: String) -> some View {
        let hot = hoveredZone == zone
        return VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold))
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(hot ? 1 : 0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hot ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hot ? Color.accentColor : Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: hot ? [] : [5, 4]))
        )
        .scaleEffect(hot ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: hot)
        .background(GeometryReader { geo in
            Color.clear.preference(key: DropZoneFramesKey.self, value: [zone: geo.frame(in: .named("notchDrop"))])
        })
    }

    /// AirDrop / zip / clear for everything on the shelf.
    private var shelfActionsMenu: some View {
        Menu {
            Button { ShelfActions.airDrop(viewModel.shelfItems.map(\.url)) } label: {
                Label(Localizer.string("notch.airdrop_all"), systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                ShelfActions.zip(viewModel.shelfItems.map(\.url)) { archive in
                    if let archive { viewModel.addShelfItem(url: archive) }
                }
            } label: {
                Label(Localizer.string("notch.zip_all"), systemImage: "doc.zipper")
            }
            Divider()
            Button(role: .destructive) { viewModel.clearShelf() } label: {
                Label(Localizer.string("notch.clear_shelf"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
    static let controlRowHeight: CGFloat = 38

    private var availableTabs: [NotchLowerTab] {
        var tabs: [NotchLowerTab] = []
        if viewModel.showShelf { tabs.append(.files) }
        if viewModel.showShelf && viewModel.clipboardHistoryEnabled { tabs.append(.clipboard) }
        if viewModel.showProductivity { tabs.append(.note) }
        if viewModel.showMirror { tabs.append(.mirror) }
        return tabs
    }

    private var currentTab: NotchLowerTab {
        if isDraggingOver, availableTabs.contains(.files) { return .files }
        return availableTabs.contains(viewModel.lowerTab) ? viewModel.lowerTab : (availableTabs.first ?? .files)
    }

    private var lowerTabs: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(availableTabs, id: \.self) { tab in
                    tabButton(tab)
                }
                Spacer()
                switch currentTab {
                case .note:
                    pomodoroCompact
                case .mirror:
                    EmptyView()
                case .files:
                    shelfSearchField
                    if !viewModel.shelfItems.isEmpty { shelfActionsMenu }
                case .clipboard:
                    shelfSearchField
                }
            }
            .frame(height: Self.tabBarHeight)

            Group {
                switch currentTab {
                case .files: filesCard
                case .clipboard: card { clipboardHistoryContent }
                case .note: noteCard
                case .mirror: card { MirrorView() }
                }
            }
            .frame(height: cardHeight)
        }
    }

    @State private var copiedID: UUID?

    /// One shelf/clipboard tile: thumbnail + title, with a clear selected
    /// state while its Quick Look preview is open.
    private func shelfTile<Thumb: View>(selected: Bool, title: String, @ViewBuilder thumbnail: () -> Thumb) -> some View {
        VStack(spacing: 5) {
            thumbnail()
                .frame(width: 52, height: 52)
            Text(title)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .white.opacity(0.8))
                .lineLimit(1)
                .frame(width: 66)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.35) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    /// The notch's frame on screen, so Quick Look opens right below it.
    private var notchAnchor: CGRect? {
        guard let frame = NSApp.windows.first(where: { $0.contentView is NSHostingView<NotchContentView> })?.frame else { return nil }
        return CGRect(x: frame.minX, y: frame.maxY - expandedHeight, width: frame.width, height: expandedHeight)
    }

    private func closePreviewIfShowing(_ url: URL) {
        if preview.isVisible && preview.currentURL == url { QLPreviewPanel.shared()?.orderOut(nil) }
    }

    private func previewFiles(_ url: URL) {
        preview.toggle(urls: filteredShelf.map(\.url), selected: url, below: notchAnchor)
    }

    private func previewClipboard(_ item: ClipboardHistoryItem) {
        let urls = filteredClipboard.map(ShelfPreview.previewURL(for:))
        preview.toggle(urls: urls, selected: ShelfPreview.previewURL(for: item), below: notchAnchor)
    }

    private func copyWithFeedback(_ item: ClipboardHistoryItem) {
        clipboardHistory.copyToPasteboard(item)
        withAnimation { copiedID = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { if copiedID == item.id { copiedID = nil } }
        }
    }

    @State private var shelfQuery = ""
    @State private var searchOpen = false

    private var filteredShelf: [ShelfItem] {
        let q = shelfQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? viewModel.shelfItems : viewModel.shelfItems.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var filteredClipboard: [ClipboardHistoryItem] {
        let q = shelfQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? clipboardHistory.items : clipboardHistory.items.filter { $0.value.localizedCaseInsensitiveContains(q) }
    }

    /// A magnifier that opens into a small field filtering the shelf or
    /// the clipboard, whichever tab is showing.
    private var shelfSearchField: some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    searchOpen.toggle()
                    if !searchOpen { shelfQuery = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(searchOpen ? 0.9 : 0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if searchOpen {
                TextField(Localizer.string("notch.search"), text: $shelfQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 110)
            }
        }
        .padding(.horizontal, searchOpen ? 6 : 0)
        .frame(height: Self.tabBarHeight)
        .background(Capsule().fill(Color.white.opacity(searchOpen ? 0.12 : 0)))
    }

    private func tabButton(_ tab: NotchLowerTab) -> some View {
        let (title, icon): (String, String) = switch tab {
        case .files: (Localizer.string("notch.shelf_tab_files"), "tray.and.arrow.down")
        case .clipboard: (Localizer.string("notch.shelf_tab_clipboard"), "doc.on.clipboard")
        case .note: (Localizer.string("notch.tab_note"), "note.text")
        case .mirror: (Localizer.string("notch.tab_mirror"), "camera")
        }
        let selected = currentTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { viewModel.lowerTab = tab }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.5))
                .padding(.horizontal, 10)
                .frame(height: Self.tabBarHeight)
                .background(Capsule().fill(selected ? Color.white.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Inner surfaces: a lighter, glassy card on the black shell.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                )
            content()
        }
    }

    private var noteCard: some View {
        noteCardBody.background(frameReporter("note"))
    }

    /// Reports a control's frame (window coordinates) for the tests.
    private func frameReporter(_ key: String) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { viewModel.layoutFrames[key] = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { viewModel.layoutFrames[key] = $0 }
        }
    }

    private var noteCardBody: some View {
        card {
            ZStack(alignment: .topLeading) {
                if viewModel.quickNoteText.isEmpty {
                    Text(Localizer.string("notch.quick_note_placeholder"))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 10)
                        .padding(.leading, 13)
                        .allowsHitTesting(false)
                }
                // TextEditor, not TextField(axis:): the latter's Auto Layout
                // negotiation crashes inside the frame-sized hosting view.
                TextEditor(text: Binding(
                    get: { viewModel.quickNoteText },
                    set: { viewModel.quickNoteText = $0 }
                ))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    /// Pomodoro sits in the tab strip while the note is showing.
    private var pomodoroCompact: some View {
        HStack(spacing: 6) {
            Text(pomodoroTimeString)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(viewModel.pomodoroRunning ? Color.orange : .white.opacity(0.8))
            Button {
                viewModel.togglePomodoro()
            } label: {
                Image(systemName: viewModel.pomodoroRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notch.pomodoro.toggle")
            .background(frameReporter("pomodoro"))
            Button {
                viewModel.resetPomodoro()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            ForEach([15, 25, 30, 45, 60, 90], id: \.self) { minutes in
                Button(String(format: Localizer.string("notch.minutes_value"), minutes)) {
                    viewModel.pomodoroMinutes = minutes
                    SharedPreferences.shared.notchPomodoroMinutes = Double(minutes)
                    viewModel.resetPomodoro()
                }
            }
        }
        .help(Localizer.string("notch.pomodoro_help"))
    }

    // MARK: - Control row

    private var controlRow: some View {
        HStack(spacing: 8) {
            NotchSlider(
                value: controls.brightness,
                icon: controls.brightness < 0.4 ? "sun.min.fill" : "sun.max.fill",
                enabled: controls.canSetBrightness
            ) { controls.setBrightness($0) }
            NotchSlider(
                value: controls.isMuted ? 0 : controls.volume,
                icon: volumeIcon,
                enabled: controls.canSetVolume,
                onIconTap: { controls.toggleMute() }
            ) { controls.setVolume($0) }
            if viewModel.showCaffeinate {
                caffeinateButton
            }
        }
        .frame(height: Self.controlRowHeight)
        .onAppear { controls.refresh() }
    }

    private var volumeIcon: String {
        if controls.isMuted || controls.volume == 0 { return "speaker.slash.fill" }
        if controls.volume < 0.33 { return "speaker.wave.1.fill" }
        if controls.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var pomodoroTimeString: String {
        let mins = viewModel.pomodoroRemaining / 60
        let secs = viewModel.pomodoroRemaining % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Keep-awake tile: click toggles (until turned off), right-click picks
    /// a duration. Shows the time left while a timed session runs.
    private var caffeinateButton: some View {
        Button {
            caffeinate.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: caffeinate.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(caffeinateLabel)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(caffeinate.isActive ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: Self.controlRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(caffeinate.isActive ? Color.orange : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(caffeinate.isActive ? 0 : 0.1), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeInOut(duration: 0.18), value: caffeinate.isActive)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(Array(CaffeinateService.presets.enumerated()), id: \.offset) { _, duration in
                Button(Self.durationTitle(duration)) { caffeinate.activate(for: duration) }
            }
            if caffeinate.isActive {
                Divider()
                Button(Localizer.string("notch.awake_turn_off")) { caffeinate.deactivate() }
            }
        }
        .help(Localizer.string("notch.awake_help"))
    }

    private var caffeinateLabel: String {
        guard caffeinate.isActive else { return Localizer.string("notch.awake_off") }
        guard let end = caffeinate.endDate else { return Localizer.string("notch.awake_on") }
        let minutes = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return minutes >= 60 ? "\(minutes / 60)\(Localizer.string("notch.hour_short")) \(minutes % 60)\(Localizer.string("notch.minute_short"))"
                             : "\(minutes)\(Localizer.string("notch.minute_short"))"
    }

    static func durationTitle(_ duration: TimeInterval?) -> String {
        guard let duration else { return Localizer.string("notch.awake_indefinite") }
        let minutes = Int(duration / 60)
        return minutes >= 60
            ? String(format: Localizer.string("notch.awake_hours"), minutes / 60)
            : String(format: Localizer.string("notch.awake_minutes"), minutes)
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
            // A small dark calendar tile that sits quietly on the black notch.
            VStack(spacing: 0) {
                Text(localizedDate(.dateTime.month(.abbreviated)))
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(Color(red: 1, green: 0.36, blue: 0.33))
                    .textCase(.uppercase)
                    .padding(.top, 3)
                Text(localizedDate(.dateTime.day()))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .offset(y: -1)
            }
            .frame(width: 32, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            )
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

    /// One line, like the menu bar clock: "Pzt 28 Eyl".
    private var compactCalendar: some View {
        HStack(spacing: 5) {
            Text(localizedDate(.dateTime.weekday(.abbreviated)))
                .foregroundStyle(.white.opacity(0.55))
            Text(localizedDate(.dateTime.day().month(.abbreviated)))
                .foregroundStyle(.white)
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func localizedDate(_ style: Date.FormatStyle) -> String {
        viewModel.currentDate.formatted(style.locale(Localizer.currentLocale))
    }



    private var filesCard: some View {
        VStack(spacing: 0) {
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
                } else if filteredShelf.isEmpty {
                    Text(Localizer.string("menubar.no_match")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(filteredShelf) { item in
                                shelfTile(selected: preview.currentURL == item.url, title: item.name) {
                                    ShelfThumbnail(url: item.url)
                                }
                                .onTapGesture {
                                    // One gesture, so a single click isn't held back
                                    // waiting to see whether a second one follows.
                                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                                        closePreviewIfShowing(item.url)
                                        NSWorkspace.shared.open(item.url)
                                    } else {
                                        previewFiles(item.url)
                                    }
                                }
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
                                    Button(Localizer.string("notch.preview")) { previewFiles(item.url) }
                                    Button("AirDrop") { ShelfActions.airDrop([item.url]) }
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
                        .fill(.black.opacity(0.78))
                    HStack(spacing: 8) {
                        dropZone(.shelf, title: Localizer.string("notch.drop_shelf"), icon: "tray.and.arrow.down.fill")
                        dropZone(.airdrop, title: "AirDrop", icon: "dot.radiowaves.left.and.right")
                        dropZone(.zip, title: Localizer.string("notch.drop_zip"), icon: "doc.zipper")
                    }
                    .padding(8)
                }
            }
            .frame(height: Self.tabCardHeight)
            .animation(.easeOut(duration: 0.18), value: isDraggingOver)
        }
    }

    private var clipboardHistoryContent: some View {
        Group {
            if clipboardHistory.items.isEmpty {
                Label(Localizer.string("notch.clipboard_empty"), systemImage: "doc.on.clipboard").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            } else if filteredClipboard.isEmpty {
                Text(Localizer.string("menubar.no_match")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(filteredClipboard) { item in
                            let url = ShelfPreview.previewURL(for: item)
                            shelfTile(selected: preview.currentURL == url, title: item.previewText.replacingOccurrences(of: "\n", with: " ")) {
                                if item.kind == .fileURL || item.kind == .image {
                                    ShelfThumbnail(url: url)
                                } else {
                                    Text(item.value)
                                        .font(.system(size: 6.5))
                                        .foregroundStyle(.black.opacity(0.75))
                                        .lineLimit(7)
                                        .frame(width: 44, height: 50, alignment: .topLeading)
                                        .padding(4)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.92)))
                                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                                }
                            }
                            .onTapGesture {
                                if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                                    closePreviewIfShowing(ShelfPreview.previewURL(for: item))
                                    copyWithFeedback(item)
                                } else {
                                    previewClipboard(item)
                                }
                            }
                            .onHover { hovering in
                                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                            .overlay(alignment: .top) {
                                if copiedID == item.id {
                                    Text(Localizer.string("notch.copied"))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.green))
                                        .transition(.opacity)
                                }
                            }
                            .contextMenu {
                                Button(Localizer.string("notch.preview")) { previewClipboard(item) }
                                Button(Localizer.string("notch.copy")) { copyWithFeedback(item) }
                                Divider()
                                Button(Localizer.string("notch.remove"), role: .destructive) { clipboardHistory.remove(item) }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}

/// A Control Center–style slider: a thick capsule that fills with the
/// level, icon inside, drag or click anywhere to set it.
private struct NotchSlider: View {
    let value: Double
    let icon: String
    let enabled: Bool
    var onIconTap: (() -> Void)? = nil
    let onChange: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geo in
            let shown = dragValue ?? value
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(Color.white.opacity(enabled ? 0.92 : 0.3))
                    .frame(width: max(geo.size.height, geo.size.width * shown))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .frame(width: geo.size.height)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        // A click on the icon (e.g. mute) isn't a level change.
                        if onIconTap != nil, g.startLocation.x < geo.size.height,
                           abs(g.translation.width) < 3 { return }
                        let v = min(max(g.location.x / geo.size.width, 0), 1)
                        dragValue = v
                        onChange(v)
                    }
                    .onEnded { g in
                        defer { dragValue = nil }
                        if let onIconTap, g.startLocation.x < geo.size.height, abs(g.translation.width) < 3 {
                            onIconTap()
                        }
                    }
            )
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

/// A file's Quick Look thumbnail (photos show the picture, documents their
/// first page), falling back to the Finder icon.
private struct ShelfThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .task(id: url) { image = await ShelfThumbnailCache.shared.thumbnail(for: url) }
    }
}

@MainActor
final class ShelfThumbnailCache {
    static let shared = ShelfThumbnailCache()
    private var cache: [URL: NSImage] = [:]

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 104, height: 104),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        cache[url] = rep.nsImage
        return rep.nsImage
    }
}

/// Quick Look (the real space-bar preview) for shelf files, with arrow
/// keys moving between them.
@MainActor
final class ShelfPreview: NSObject, ObservableObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ShelfPreview()
    private var urls: [URL] = []
    private var indexObservation: NSKeyValueObservation?
    private var closeObserver: Any?

    /// The item being previewed — the notch highlights it.
    @Published private(set) var currentURL: URL?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false) }

    /// Opens Quick Look on `selected`, or closes it if that item is already
    /// showing (click again to dismiss).
    func toggle(urls: [URL], selected: URL, below anchor: CGRect?) {
        if isVisible, currentURL == selected {
            QLPreviewPanel.shared()?.orderOut(nil)
            currentURL = nil
            return
        }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = urls.firstIndex(of: selected) ?? 0
        currentURL = selected

        indexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] panel, _ in
            let index = panel.currentPreviewItemIndex
            Task { @MainActor in
                guard let self, self.urls.indices.contains(index) else { return }
                self.currentURL = self.urls[index]
            }
        }
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.currentURL = nil }
            }
        }

        // Quick Look needs the app active to take arrow keys / Space.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Right under the notch instead of the middle of the screen.
        if let anchor, let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            let size = CGSize(width: min(720, screen.visibleFrame.width - 80), height: min(520, screen.visibleFrame.height * 0.6))
            let frame = CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 10,
                               width: size.width, height: size.height)
            panel.setFrame(frame, display: true, animate: false)
        }
        panel.orderFrontRegardless()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }

    /// Text copied to the clipboard is previewed from a small temp file.
    static func previewURL(for item: ClipboardHistoryItem) -> URL {
        if item.kind == .fileURL { return URL(fileURLWithPath: item.value) }
        if let image = ClipboardHistoryService.shared.imageURL(for: item) { return image }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentClipboardPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(item.id.uuidString).txt")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? item.value.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}

// MARK: - Drop zones

enum DropZone: Hashable { case shelf, airdrop, zip }

private struct DropZoneFramesKey: PreferenceKey {
    static var defaultValue: [DropZone: CGRect] = [:]
    static func reduce(value: inout [DropZone: CGRect], nextValue: () -> [DropZone: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Tracks where a file drag is over the notch so the drop lands in the
/// zone under the pointer (anywhere else = shelf).
private struct NotchDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var hoveredZone: DropZone?
    let zones: [DropZone: CGRect]
    let perform: (DropZone?, [NSItemProvider]) -> Void

    private func zone(at point: CGPoint) -> DropZone? {
        zones.first { $0.value.contains(point) }?.key
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { isTargeted = true; hoveredZone = zone(at: info.location) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Called for every mouse move — only touch state when the zone changes.
        let zone = zone(at: info.location)
        if zone != hoveredZone { hoveredZone = zone }
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { isTargeted = false; hoveredZone = nil }
    func performDrop(info: DropInfo) -> Bool {
        let target = zone(at: info.location)
        perform(target, info.itemProviders(for: [.fileURL]))
        isTargeted = false
        hoveredZone = nil
        return true
    }
}

// MARK: - Shelf actions

@MainActor
enum ShelfActions {
    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Zips the files into ~/Downloads ("Augment 2026-09-28 21.40.zip") in
    /// the background and hands back the archive.
    static func zip(_ urls: [URL], completion: @escaping @MainActor (URL?) -> Void) {
        guard !urls.isEmpty else { completion(nil); return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Augment \(formatter.string(from: Date()))"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            var archive = downloads.appendingPathComponent("\(name).zip")
            var n = 2
            while FileManager.default.fileExists(atPath: archive.path) {
                archive = downloads.appendingPathComponent("\(name) \(n).zip"); n += 1
            }
            // Stage clones of everything in one folder so ditto zips them together.
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("AugmentZip-\(UUID().uuidString)/\(name)")
            defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
            var ok = (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil
            for url in urls where ok {
                ok = (try? FileManager.default.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))) != nil
            }
            if ok {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                let source = urls.count == 1 ? staging.appendingPathComponent(urls[0].lastPathComponent) : staging
                task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path]
                ok = (try? task.run()) != nil
                task.waitUntilExit()
                ok = ok && task.terminationStatus == 0
            }
            let result = ok ? archive : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if result != nil { NSSound(named: "Pop")?.play() } else { NSSound.beep() }
                    completion(result)
                }
            }
        }
    }
}
