import AppKit
import Foundation

/// Renders a `DirectoryNode` into self-contained HTML suitable for a
/// `QLPreviewReply`. The output uses `prefers-color-scheme` so the preview
/// matches the system appearance with no JavaScript dependency.
enum DirectoryTreeFormatter {

    static func renderHTML(root: DirectoryNode, originalURL: URL) -> String {
        let bytes = formatBytes(root.byteSize)
        let nestedFiles = countDescendants(root)
        let immediateEntries = root.children.count
        let skipped = countSkipped(root)
        let modifiedSegment: String
        if let date = root.modifiedAt {
            modifiedSegment = "<span class=\"chip\">Güncelleme <strong>\(escape(formatDate(date)))</strong></span>"
        } else {
            modifiedSegment = ""
        }
        // The brand chip is small but important: it lets the user
        // visually distinguish Augment's preview from the system default
        // at a glance. Several Phase 7 reports were "Augment's tree
        // doesn't show" when in fact macOS was picking another folder
        // preview extension; this strip makes the answer obvious.
        let header = """
        <header class="ql-toolbar">
            <div class="toolbar-top">
                <span class="brand-mark">Augment</span>
                <span class="toolbar-subtitle">Klasör önizlemesi</span>
            </div>
            <div class="toolbar-title-row">
                <h1 class="toolbar-title">\(escape(root.name))</h1>
                <a class="reveal-btn root-reveal-btn" href="\(escape(originalURL.absoluteString))">
                    <span class="btn-icon"></span>Finder’da göster
                </a>
            </div>
            <p class="toolbar-path">\(escape(originalURL.path))</p>
            <div class="meta-chips">
                <span class="chip"><strong>\(immediateEntries)</strong> öğe</span>
                <span class="chip"><strong>\(nestedFiles)</strong> dosya</span>
                <span class="chip"><strong>\(bytes)</strong></span>
                \(modifiedSegment)\(skipped > 0 ? "<span class=\"chip warn\"><strong>\(skipped)</strong> özet</span>" : "")
            </div>
        </header>
        """

        var body: String
        if root.children.isEmpty {
            body = "<div class=\"empty\"><span class=\"empty-icon\" aria-hidden=\"true\"></span><span>Bu klasör boş.</span></div>"
        } else {
            body = """
            <div class="finder-panel" role="tree">
                <div class="colhead" aria-hidden="true">
                    <span class="col-name">Ad</span>
                    <span class="col-date">Değiştirme</span>
                    <span class="col-size">Boyut</span>
                </div>
                <ul class=\"tree root\">
            """
            for child in root.children {
                body.append(renderNode(child, depth: 0, parentDirURL: originalURL))
            }
            body.append("</ul></div>")
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
            \(stylesheet)
        </style>
        </head>
        <body>
        \(header)
        <main>\(body)</main>
        <p class="hint-footer">Klasör satırındaki okla alt öğeler burada açılır. Dosyaya tıklayınca sistem Quick Look (Finder’daki Space ile aynı) açılır. "Finder'da göster" bağlantısı klasörü Finder’da seçer.</p>
        </body>
        </html>
        """
    }

    // MARK: - Node rendering

    /// `parentDirURL` is the directory whose immediate children we are listing (the previewed folder at root).
    private static func renderNode(_ node: DirectoryNode, depth: Int, parentDirURL: URL) -> String {
        switch node.kind {
        case .file:
            let fileURL = parentDirURL.appendingPathComponent(node.name, isDirectory: false)
            let href = escape(fileURL.absoluteString)
            let size = "<span class=\"cell size\">\(formatBytes(node.byteSize))</span>"
            let modified = renderModifiedCell(node.modifiedAt)
            let glyph = "<img class=\"glyph-icon\" src=\"\(fileIconDataURI(for: node.name))\" alt=\"\">"
            let title = escape(node.name)
            return """
            <li class="file row" role="treeitem"><div class="name-cell">\(glyph)<a class="name-link" href="\(href)" title="\(title)">\(title)</a></div>\(modified)\(size)</li>
            """

        case .directory:
            let dirURL = parentDirURL.appendingPathComponent(node.name, isDirectory: true)
            let opened = depth < 1 ? " open" : ""
            let size = "<span class=\"cell size\">\(formatBytes(node.byteSize))</span>"
            let modified = renderModifiedCell(node.modifiedAt)
            let itemMeta = "<span class=\"item-meta\">\(node.children.count) öğe</span>"
            let folderHref = escape(dirURL.absoluteString)
            let summaryTitle = escape(node.name)
            var html = """
            <li class="dir" role="treeitem">
            <details class="nest"\(opened)>
            <summary class="row summary-row"><div class="name-cell folder-head"><span class="disclosure" aria-hidden="true"></span><span class="folder-label">\(summaryTitle)</span>\(itemMeta)</div>\(modified)\(size)</summary>
            <div class="nested-sheet">
            <div class="folder-actions">
                <a class="reveal-btn" href="\(folderHref)">
                    <span class="btn-icon"></span>Finder’da göster
                </a>
            </div>
            <ul class="tree nested">
            """
            for child in node.children {
                html.append(renderNode(child, depth: depth + 1, parentDirURL: dirURL))
            }
            html.append("</ul></div></details></li>")
            return html

        case .directorySkipped(let reason):
            let label: String
            switch reason {
            case .ignoredName: label = "summarized"
            case .depthBudget: label = "depth limit"
            case .fileBudget: label = "size limit"
            case .timeBudget: label = "time limit"
            case .unreadable: label = "unreadable"
            }
            let modified = renderModifiedCell(node.modifiedAt)
            let title = escape(node.name)
            return """
            <li class="dir skipped row" role="treeitem"><div class="name-cell"><span class="glyph dim" aria-hidden="true">◐</span><span class="folder-label muted">\(title)</span></div>\(modified)<span class="cell size badge-wrap"><span class="badge">\(label)</span></span></li>
            """
        }
    }

    private static func renderModifiedCell(_ date: Date?) -> String {
        guard let date else {
            return "<span class=\"cell date\">—</span>"
        }
        return "<span class=\"cell date\">\(escape(formatDate(date)))</span>"
    }

    /// Extension → data-URI cache. `NSWorkspace.icon(forFileType:)` is a
    /// generic per-type icon lookup (no disk read of the actual file), so a
    /// folder with hundreds of `.swift`/`.png` files only pays the icon +
    /// PNG-encode cost once per distinct extension, not once per row.
    private static var fileIconCache: [String: String] = [:]

    /// Real system file-type icons instead of a hand-picked emoji table —
    /// matches what Finder itself shows, covers every extension (not just
    /// the ones we bothered to special-case), and looks native rather than
    /// like a text-tree glyph column.
    private static func fileIconDataURI(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let cacheKey = ext.isEmpty ? "__noext__" : ext
        if let cached = fileIconCache[cacheKey] { return cached }

        let icon = ext.isEmpty
            ? NSWorkspace.shared.icon(forFileType: "")
            : NSWorkspace.shared.icon(forFileType: ext)
        icon.size = NSSize(width: 32, height: 32)

        var base64 = ""
        if let tiff = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            base64 = png.base64EncodedString()
        }
        let uri = "data:image/png;base64,\(base64)"
        fileIconCache[cacheKey] = uri
        return uri
    }

    // MARK: - Aggregates

    private static func countDescendants(_ node: DirectoryNode) -> Int {
        switch node.kind {
        case .file: return 1
        case .directorySkipped: return 0
        case .directory:
            return node.children.reduce(0) { $0 + countDescendants($1) }
        }
    }

    private static func countSkipped(_ node: DirectoryNode) -> Int {
        switch node.kind {
        case .file: return 0
        case .directorySkipped: return 1
        case .directory:
            return node.children.reduce(0) { $0 + countSkipped($1) }
        }
    }

    // MARK: - Helpers

    static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Compact "modified" timestamp shown next to each row. The format
    /// matches the user's locale so the date column reads naturally next
    /// to Finder; we cap it at minute precision because Quick Look
    /// previews are an at-a-glance surface, not an audit log.
    private static let modifiedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func formatDate(_ date: Date) -> String {
        modifiedFormatter.string(from: date)
    }

    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    // MARK: - Stylesheet (Finder-style list, nested “sheet” for subfolders)

    private static let stylesheet: String = """
    :root {
        color-scheme: light dark;
        --fg: #1d1d1f;
        --secondary: #6e6e73;
        --bg: #e8e8ed;
        --panel: #ffffff;
        --separator: rgba(60,60,67,0.18);
        --row-hover: rgba(0,0,0,0.05);
        --badge-bg: rgba(60,60,67,0.09);
        --badge-fg: #6e6e73;
        --warn: #b15c00;
        --accent: #007aff;
        --nested-tint: rgba(0,122,255,0.08);
        --link: #007aff;
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --fg: #f5f5f7;
            --secondary: #a1a1a6;
            --bg: #0f0f0f;
            --panel: #202022;
            --separator: rgba(235,235,245,0.08);
            --row-hover: rgba(255,255,255,0.06);
            --badge-bg: rgba(235,235,245,0.1);
            --badge-fg: #a1a1a6;
            --warn: #ff9f0a;
            --accent: #0a84ff;
            --nested-tint: rgba(10,132,255,0.12);
            --link: #409fff;
        }
    }
    * { box-sizing: border-box; }
    html, body {
        margin: 0;
        padding: 0;
        background: var(--bg);
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Helvetica Neue", sans-serif;
        font-size: 13px;
        line-height: 1.4;
        -webkit-font-smoothing: antialiased;
    }
    .ql-toolbar {
        padding: 12px 18px 12px;
        background: var(--panel);
        border-bottom: 1px solid var(--separator);
        position: sticky;
        top: 0;
        z-index: 5;
    }
    .toolbar-top {
        display: flex;
        align-items: baseline;
        gap: 8px;
        margin-bottom: 4px;
    }
    .brand-mark {
        font-size: 11px;
        font-weight: 700;
        letter-spacing: -0.02em;
        color: var(--accent);
    }
    .toolbar-subtitle {
        font-size: 11px;
        font-weight: 500;
        color: var(--secondary);
    }
    .toolbar-title {
        font-size: 16px;
        font-weight: 600;
        letter-spacing: -0.02em;
        margin: 0 0 2px 0;
    }
    .toolbar-path {
        font-size: 11px;
        color: var(--secondary);
        margin: 0 0 8px 0;
        word-break: break-all;
    }
    .meta-chips {
        display: flex;
        flex-wrap: wrap;
        gap: 6px 10px;
    }
    .chip {
        font-size: 11px;
        color: var(--secondary);
        background: var(--badge-bg);
        padding: 3px 8px;
        border-radius: 6px;
    }
    .chip.warn { color: var(--warn); }
    main {
        padding: 10px 16px 10px;
    }
    .finder-panel {
        background: var(--panel);
        border: 1px solid var(--separator);
        border-radius: 10px;
        overflow: hidden;
        box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }
    @media (prefers-color-scheme: dark) {
        .finder-panel { box-shadow: 0 1px 2px rgba(0,0,0,0.4); }
    }
    .colhead {
        display: grid;
        grid-template-columns: minmax(0,1fr) 124px 80px;
        gap: 8px 12px;
        align-items: center;
        padding: 5px 12px 5px 12px;
        font-size: 11px;
        font-weight: 600;
        color: var(--secondary);
        text-transform: uppercase;
        letter-spacing: 0.02em;
        background: rgba(0, 0, 0, 0.03);
        border-bottom: 1px solid var(--separator);
    }
    @media (prefers-color-scheme: dark) {
        .colhead {
            background: rgba(255, 255, 255, 0.05);
        }
    }
    .col-name { grid-column: 1; }
    .col-date { grid-column: 2; text-align: right; }
    .col-size { grid-column: 3; text-align: right; }
    ul.tree {
        list-style: none;
        margin: 0;
        padding: 4px 0 6px 0;
    }
    ul.tree.root {
        padding-left: 0;
    }
    .row {
        display: grid;
        grid-template-columns: minmax(0,1fr) 124px 80px;
        gap: 8px 12px;
        align-items: center;
        padding: 5px 12px;
        margin: 0 4px;
        border-radius: 6px;
        min-height: 28px;
    }
    li.file.row:hover, li.dir.skipped.row:hover {
        background: var(--row-hover);
    }
    .name-cell {
        display: flex;
        align-items: center;
        gap: 8px;
        min-width: 0;
    }
    .folder-head {
        gap: 6px;
    }
    .glyph {
        flex-shrink: 0;
        width: 22px;
        text-align: center;
        font-size: 12px;
        opacity: 0.85;
    }
    .glyph.dim { opacity: 0.45; }
    .glyph-icon {
        flex-shrink: 0;
        width: 18px;
        height: 18px;
        object-fit: contain;
    }
    .toolbar-title-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 10px;
    }
    .root-reveal-btn {
        flex-shrink: 0;
    }
    .name-link {
        color: var(--link);
        text-decoration: none;
        font-weight: 500;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        min-width: 0;
    }
    .name-link:hover { text-decoration: underline; }
    .folder-label {
        font-weight: 500;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        min-width: 0;
    }
    .folder-label.muted { color: var(--secondary); font-weight: 400; }
    .item-meta {
        font-size: 11px;
        font-weight: 400;
        color: var(--secondary);
        flex-shrink: 0;
    }
    .cell.date, .cell.size {
        font-size: 12px;
        font-variant-numeric: tabular-nums;
        color: var(--secondary);
        text-align: right;
    }
    .cell.size.badge-wrap {
        display: flex;
        justify-content: flex-end;
    }
    .badge {
        font-size: 10px;
        font-weight: 600;
        background: var(--badge-bg);
        color: var(--badge-fg);
        padding: 2px 7px;
        border-radius: 4px;
        text-transform: uppercase;
        letter-spacing: 0.03em;
    }
    details.nest > summary {
        list-style: none;
        cursor: pointer;
        padding: 0;
        margin: 0;
    }
    details.nest > summary::-webkit-details-marker { display: none; }
    details.nest > summary.summary-row:hover {
        background: var(--row-hover);
    }
    .folder-head .disclosure {
        flex-shrink: 0;
        width: 14px;
        height: 14px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
    }
    .folder-head .disclosure::before {
        content: "";
        width: 6px;
        height: 6px;
        border-right: 2px solid var(--secondary);
        border-bottom: 2px solid var(--secondary);
        transform: rotate(-45deg);
        transition: transform 0.18s ease;
        margin-top: -2px;
    }
    details.nest[open] > summary .folder-head .disclosure::before {
        transform: rotate(45deg);
        margin-top: 0;
    }
    .nested-sheet {
        margin: 2px 8px 10px 22px;
        padding: 8px 10px 10px 12px;
        border-radius: 8px;
        border-left: 3px solid var(--accent);
        background: var(--nested-tint);
    }
    .folder-actions {
        margin-bottom: 10px;
        display: flex;
        justify-content: flex-start;
    }
    .reveal-btn {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        font-size: 11px;
        font-weight: 600;
        color: var(--accent);
        text-decoration: none;
        background: var(--badge-bg);
        padding: 4px 10px;
        border-radius: 6px;
        transition: all 0.2s ease;
    }
    .reveal-btn:hover {
        background: var(--accent);
        color: white;
    }
    .reveal-btn .btn-icon::before {
        content: "↗";
        font-size: 12px;
    }
    ul.tree.nested {
        padding-left: 0;
        margin-top: 4px;
        border-top: 1px solid var(--separator);
        padding-top: 8px;
    }
    .empty {
        padding: 28px 16px;
        text-align: center;
        color: var(--secondary);
        font-size: 13px;
    }
    .empty-icon {
        width: 44px;
        height: 34px;
        margin: 0 auto 12px;
        border-radius: 8px;
        border: 1.5px solid var(--separator);
        background: linear-gradient(165deg, rgba(0,0,0,0.05), transparent);
    }
    .hint-footer {
        margin: 10px 18px 18px;
        font-size: 11px;
        line-height: 1.45;
        color: var(--secondary);
        padding-top: 8px;
        border-top: 1px solid var(--separator);
    }
    details.nest:not([open]) > .nested-sheet {
        content-visibility: hidden;
    }
    .nested-sheet {
        content-visibility: auto;
        contain-intrinsic-size: auto 200px;
    }
    """
}
