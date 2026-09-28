import Cocoa
import CoreFoundation
import FinderSync
import os

/// Principal class for the Augment Finder Sync extension.
///
/// Adds a "New File…" item to Finder's contextual menu, with categorized
/// submenus (Coding, Microsoft Office, Data, Text). Each item creates a
/// real file inside the directory the user right-clicked, using either
/// text seeds or proper minimal Open XML templates that ship inside the
/// extension bundle.
final class FinderSync: FIFinderSync {

    private let categories: [FileTemplateCategory] = FileTemplateFactory.allCategories()
    /// Flat lookup table keyed by the integer tags we attach to every
    /// `NSMenuItem`. Resolves a tag back to a concrete `FileTemplate` when
    /// the user picks an item.
    private let flatTemplates: [FileTemplate] = FileTemplateFactory.allTemplates()
    private var currentMenuKind: FIMenuKind?

    /// Paths the user cut with ⌘X in Augment; they get the "cut" badge.
    private var cutPaths = Set<String>()
    private static let cutBadge = "augment.cut"

    override init() {
        super.init()
        Self.log.notice("FinderSync extension started")
        let controller = FIFinderSyncController.default()
        controller.directoryURLs = [URL(fileURLWithPath: "/")]
        controller.setBadgeImage(Self.makeCutBadgeImage(), label: Self.cutBadgeLabel, forBadgeIdentifier: Self.cutBadge)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(cutSetChanged),
            name: AppGroup.fileCutChangedNotification,
            object: nil
        )
        cutSetChanged()
    }

    // FinderSync framework requires `beginObservingDirectory` and the
    // companion `endObservingDirectory` to exist for the extension to be
    // loaded reliably.
    override func beginObservingDirectory(at url: URL) { }
    override func endObservingDirectory(at url: URL) { }

    // MARK: - Cut badge

    override func requestBadgeIdentifier(for url: URL) {
        guard cutPaths.contains(Self.normalized(url.path)) else { return }
        FIFinderSyncController.default().setBadgeIdentifier(Self.cutBadge, for: url)
    }

    /// Re-reads the cut set and updates only the items whose state changed.
    @objc private func cutSetChanged() {
        AppGroup.synchronizeSuitePreferences()
        let paths = (AppGroup.copySuiteValue(forKey: AppGroupKey.fileCutPaths) as? [String]) ?? []
        let updated = Set(paths.map(Self.normalized))
        let controller = FIFinderSyncController.default()
        for path in cutPaths.subtracting(updated) {
            controller.setBadgeIdentifier("", for: URL(fileURLWithPath: path))
        }
        for path in updated.subtracting(cutPaths) {
            controller.setBadgeIdentifier(Self.cutBadge, for: URL(fileURLWithPath: path))
        }
        cutPaths = updated
    }

    /// Finder may report `/private/var/…` or `/var/…` for the same item.
    private static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix("/private/") ? String(standardized.dropFirst("/private".count)) : standardized
    }

    private static var cutBadgeLabel: String {
        Locale.preferredLanguages.first?.hasPrefix("tr") == true ? "Kesildi" : "Cut"
    }

    /// A scissors glyph on a soft translucent disc, readable on any icon.
    private static func makeCutBadgeImage() -> NSImage {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            NSColor(white: 1, alpha: 0.92).setFill()
            disc.fill()
            NSColor(white: 0, alpha: 0.18).setStroke()
            disc.lineWidth = 2
            disc.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
                .applying(.init(paletteColors: [.systemOrange]))
            if let glyph = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2,
                                      width: g.width, height: g.height))
            }
            return true
        }
    }

    private static let log = Logger(subsystem: "com.anilipeksumer.augment.findersync", category: "menu")

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menu = buildMenu(for: menuKind)
        Self.log.notice("menu(for: \(menuKind.rawValue, privacy: .public)) -> \(menu.items.count, privacy: .public) items")
        return menu
    }

    private func buildMenu(for menuKind: FIMenuKind) -> NSMenu {
        currentMenuKind = menuKind
        let menu = NSMenu(title: "Augment")

        // Master toggle: when the user has disabled this feature in
        // Augment Settings, we still implement the protocol but return an
        // empty menu so Finder doesn't reserve a row for us. The Finder
        // Sync extension is its own process; reading the @Published value
        // would return whatever was true when this instance was created,
        // so we re-read the stored value directly to honour live toggles.
        guard menuKind == .contextualMenuForItems
                || menuKind == .contextualMenuForContainer
                || menuKind == .contextualMenuForSidebar
        else { return menu }

        if AppGroup.preferencesBool(forKey: AppGroupKey.finderExtraMenuEnabled) {
            let copyTitle = Localizer.string("finder.copy_path")
            let copy = NSMenuItem(title: copyTitle, action: #selector(copyPath(_:)), keyEquivalent: "")
            copy.target = self
            copy.image = Self.templateSymbol("link", description: copyTitle)
            menu.addItem(copy)
            let terminalTitle = Localizer.string("finder.open_terminal")
            let terminal = NSMenuItem(title: terminalTitle, action: #selector(openTerminal(_:)), keyEquivalent: "")
            terminal.target = self
            terminal.image = Self.templateSymbol("terminal", description: terminalTitle)
            menu.addItem(terminal)
        }

        guard AppGroup.preferencesBool(forKey: AppGroupKey.finderNewFileMenuEnabled) else { return menu }

        let menuTitle = Localizer.string("finder.menu_title")
        let parent = NSMenuItem(
            title: menuTitle,
            action: nil,
            keyEquivalent: ""
        )
        parent.image = Self.templateSymbol(
            "doc.badge.plus",
            description: menuTitle
        )

        let submenu = NSMenu(title: menuTitle)
        var globalIndex = 0

        for category in categories {
            let categoryTitleKey: String
            switch category.title {
            case "Coding": categoryTitleKey = "finder.category_coding"
            case "Microsoft Office": categoryTitleKey = "finder.category_office"
            case "Data": categoryTitleKey = "finder.category_data"
            case "Project Files": categoryTitleKey = "finder.category_project"
            case "Text": categoryTitleKey = "finder.category_text"
            default: categoryTitleKey = category.title
            }
            let categoryTitle = Localizer.string(categoryTitleKey)

            // Category header (disabled but visually grouped).
            let header = NSMenuItem(title: categoryTitle, action: nil, keyEquivalent: "")
            header.image = Self.templateSymbol(
                category.symbolName,
                description: categoryTitle
            )
            // Build a per-category submenu so the contextual menu stays
            // tidy when the catalog grows.
            let categorySubmenu = NSMenu(title: categoryTitle)
            for template in category.templates {
                let templateTitleKey: String
                switch template.displayLabel {
                case "Word Document (.docx)": templateTitleKey = "finder.template_word"
                case "Excel Workbook (.xlsx)": templateTitleKey = "finder.template_excel"
                case "Rich Text (.rtf)": templateTitleKey = "finder.template_rtf"
                case "Environment (.env)": templateTitleKey = "finder.template_env"
                case "Plain Text (.txt)": templateTitleKey = "finder.template_txt"
                default: templateTitleKey = template.displayLabel
                }
                let templateTitle = Localizer.string(templateTitleKey)

                let item = NSMenuItem(
                    title: templateTitle,
                    action: #selector(handleTemplateSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = globalIndex
                item.image = Self.templateSymbol(
                    template.symbolName,
                    description: templateTitle
                )
                categorySubmenu.addItem(item)
                globalIndex += 1
            }
            header.submenu = categorySubmenu
            submenu.addItem(header)
        }

        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    /// Finder Sync can rasterize template symbols as black in dark menus.
    /// A dynamic label-color palette keeps submenu icons legible in both
    /// appearances while preserving Finder's selected-row treatment.
    private static func templateSymbol(
        _ name: String,
        description: String
    ) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.labelColor])
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: description
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    /// The items the menu was opened on (selection, or the folder itself).
    private func targetURLs() -> [URL] {
        let controller = FIFinderSyncController.default()
        if currentMenuKind == .contextualMenuForItems || currentMenuKind == .contextualMenuForSidebar,
           let selected = controller.selectedItemURLs(), !selected.isEmpty {
            return selected
        }
        return controller.targetedURL().map { [$0] } ?? []
    }

    /// Copies the POSIX path(s), one per line.
    @objc private func copyPath(_ sender: NSMenuItem) {
        let paths = targetURLs().map(\.path)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Asks Augment (unsandboxed) to open Terminal at the folder.
    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let url = targetURLs().first else { return }
        do {
            try FinderRevealBridge.enqueue(FinderRevealBridge.Request(filePath: url.path, action: "terminal"))
            ensureAugmentHostRunningForFinderBridge()
        } catch {
            presentAlert(title: Localizer.string("finder.error_generic_title"), message: error.localizedDescription)
        }
    }

    @objc private func handleTemplateSelection(_ sender: NSMenuItem) {
        guard flatTemplates.indices.contains(sender.tag) else { return }
        let controller = FIFinderSyncController.default()
        guard let directory = currentTargetDirectory(for: controller) else {
            presentAlert(
                title: Localizer.string("finder.error_cannot_determine_title"),
                message: Localizer.string("finder.error_cannot_determine_msg")
            )
            return
        }

        do {
            try FinderCreateBridge.enqueue(
                FinderCreateBridge.Request(templateTag: sender.tag, directoryPath: directory.path)
            )
            ensureAugmentHostRunningForFinderBridge()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    FinderCreateBridge.darwinNotificationName,
                    nil,
                    nil,
                    true
                )
            }
        } catch {
            presentAlert(
                title: Localizer.string("finder.error_generic_title"),
                message: Self.messageForCreateFailure(error)
            )
        }
    }

    /// Resolves the destination directory for a "New File…" command.
    ///
    /// Priority: folder targeted by the click (`targetedURL`) → selected folder(s) →
    /// parent of a selected file → directory inferred from `targetedURL` when it points at a file.
    private func currentTargetDirectory(for controller: FIFinderSyncController) -> URL? {
        switch currentMenuKind {
        case .contextualMenuForContainer, .contextualMenuForSidebar:
            return controller.targetedURL()?.standardizedFileURL
        case .contextualMenuForItems:
            guard let selected = controller.selectedItemURLs()?.first else {
                return controller.targetedURL()?.standardizedFileURL
            }
            let item = selected.standardizedFileURL
            return item.hasDirectoryPath ? item : item.deletingLastPathComponent()
        default:
            return controller.targetedURL()?.standardizedFileURL
        }
    }

    private static func messageForCreateFailure(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return Localizer.string("finder.error_no_permission")
            case NSFileWriteVolumeReadOnlyError:
                return Localizer.string("finder.error_read_only")
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// After enqueueing a create request, the **unsandboxed** Augment host
    /// must run to drain the App Group queue. Menu-bar apps are usually
    /// already active; if the user quit Augment entirely, launch it
    /// invisibly so `applicationDidFinishLaunching` flushes the plist.
    private func ensureAugmentHostRunningForFinderBridge() {
        let bundleID = "com.anilipeksumer.augment"
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID
        }
        guard !running else { return }

        // Launch Services often drops `--args` for GUI apps; mirror the signal in App Group + env.
        AppGroup.setSuiteValue(kCFBooleanTrue, forKey: AppGroupKey.pendingFinderBridgeHostLaunch)

        guard let wakeURL = URL(string: "augment://finder-bridge") else { return }
        NSWorkspace.shared.open(wakeURL)
    }
}
