import Cocoa
import CoreFoundation
import FinderSync

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

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // FinderSync framework requires `beginObservingDirectory` and the
    // companion `endObservingDirectory` to exist for the extension to be
    // loaded reliably. They're no-ops because Augment doesn't badge files
    // or watch directory contents – it only contributes a contextual menu.
    override func beginObservingDirectory(at url: URL) { }
    override func endObservingDirectory(at url: URL) { }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        currentMenuKind = menuKind
        let menu = NSMenu(title: "Augment")

        // Master toggle: when the user has disabled this feature in
        // Augment Settings, we still implement the protocol but return an
        // empty menu so Finder doesn't reserve a row for us. The Finder
        // Sync extension is its own process; reading the @Published value
        // would return whatever was true when this instance was created,
        // so we re-read the stored value directly to honour live toggles.
        guard AppGroup.preferencesBool(forKey: AppGroupKey.finderNewFileMenuEnabled) else { return menu }

        guard menuKind == .contextualMenuForItems
                || menuKind == .contextualMenuForContainer
                || menuKind == .contextualMenuForSidebar
        else { return menu }

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
