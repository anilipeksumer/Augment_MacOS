import Foundation

/// A node in the rendered Quick Look directory tree.
struct DirectoryNode {
    enum Kind {
        case directory
        case file
        /// A directory whose traversal was skipped because of one of the
        /// configured budgets (depth/file-count) or because it matches the
        /// "ignore" set. The `byteSize` is reported as the on-disk size of
        /// the directory's immediate metadata only.
        case directorySkipped(reason: SkipReason)
    }

    enum SkipReason {
        case ignoredName
        case depthBudget
        case fileBudget
        case timeBudget
        case unreadable
    }

    let name: String
    let kind: Kind
    /// Aggregate size in bytes (for directories this is the sum of every
    /// traversed descendant; for skipped directories it's `0`).
    let byteSize: UInt64
    /// Last modification timestamp, when the filesystem reports one.
    /// Surfaced in the rendered HTML so users get the same "modified"
    /// column they're used to seeing in Finder list view.
    let modifiedAt: Date?
    /// Children nodes. Empty for files and skipped directories.
    let children: [DirectoryNode]
}

/// Configuration for `DirectoryTreeBuilder`.
struct DirectoryTreeOptions {
    var maxDepth: Int = 8
    var maxEntries: Int = 8_000
    var maxDuration: TimeInterval = 2.5

    /// Directory names whose contents are summarized rather than fully
    /// traversed. Catches the usual heavy-hitters that explode preview
    /// generation time on developer machines.
    var ignoredDirectoryNames: Set<String> = [
        ".git",
        ".svn",
        ".hg",
        "node_modules",
        ".pnpm-store",
        ".yarn",
        ".cache",
        ".next",
        ".turbo",
        ".gradle",
        ".idea",
        ".venv",
        "venv",
        "__pycache__",
        "DerivedData",
        "build",
        "dist",
        "out",
        "Pods",
        ".build",
        ".tox",
        ".terraform"
    ]
}

/// Builds a `DirectoryNode` tree asynchronously, honoring depth, entry-count
/// and wall-clock budgets so the Quick Look daemon never freezes on huge
/// directories.
actor DirectoryTreeBuilder {

    private let options: DirectoryTreeOptions
    private var visitedEntries: Int = 0
    private var startTime: CFAbsoluteTime = 0

    init(options: DirectoryTreeOptions = DirectoryTreeOptions()) {
        self.options = options
    }

    /// Builds the tree rooted at `url`. The call respects task
    /// cancellation, so if the Quick Look daemon dismisses the preview
    /// the traversal stops promptly.
    func build(at url: URL) async throws -> DirectoryNode {
        startTime = CFAbsoluteTimeGetCurrent()
        visitedEntries = 0
        return try await traverse(url: url, depth: 0)
    }

    private func traverse(url: URL, depth: Int) async throws -> DirectoryNode {
        try Task.checkCancellation()

        let name = url.lastPathComponent
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .contentModificationDateKey
        ]

        let resourceValues = try? url.resourceValues(forKeys: resourceKeys)
        let isDir = resourceValues?.isDirectory ?? false
        let modifiedAt = resourceValues?.contentModificationDate

        if !isDir {
            let size = UInt64(resourceValues?.fileSize ?? 0)
            return DirectoryNode(
                name: name,
                kind: .file,
                byteSize: size,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        if options.ignoredDirectoryNames.contains(name) {
            return DirectoryNode(
                name: name,
                kind: .directorySkipped(reason: .ignoredName),
                byteSize: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        if depth >= options.maxDepth {
            return DirectoryNode(
                name: name,
                kind: .directorySkipped(reason: .depthBudget),
                byteSize: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        if visitedEntries >= options.maxEntries {
            return DirectoryNode(
                name: name,
                kind: .directorySkipped(reason: .fileBudget),
                byteSize: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        if CFAbsoluteTimeGetCurrent() - startTime > options.maxDuration {
            return DirectoryNode(
                name: name,
                kind: .directorySkipped(reason: .timeBudget),
                byteSize: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        let fm = FileManager.default
        let contents: [URL]
        do {
            // Allow hidden files at the top level so users see things like
            // `.env` / `.gitignore` in their previewed projects, but skip
            // package descendants because previewing the contents of an
            // .app or .photoslibrary as a folder is rarely useful.
            let listingOptions: FileManager.DirectoryEnumerationOptions = depth == 0
                ? [.skipsPackageDescendants]
                : [.skipsHiddenFiles, .skipsPackageDescendants]
            contents = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: listingOptions
            )
        } catch {
            return DirectoryNode(
                name: name,
                kind: .directorySkipped(reason: .unreadable),
                byteSize: 0,
                modifiedAt: modifiedAt,
                children: []
            )
        }

        var children: [DirectoryNode] = []
        children.reserveCapacity(contents.count)

        // Sort: directories first, then by name (case-insensitive).
        let sorted = contents.sorted { lhs, rhs in
            let lhsIsDir = (try? lhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rhsIsDir = (try? rhs.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if lhsIsDir != rhsIsDir { return lhsIsDir && !rhsIsDir }
            return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        var aggregateSize: UInt64 = 0
        for entry in sorted {
            try Task.checkCancellation()
            visitedEntries += 1
            let child = try await traverse(url: entry, depth: depth + 1)
            aggregateSize &+= child.byteSize
            children.append(child)
        }

        return DirectoryNode(
            name: name,
            kind: .directory,
            byteSize: aggregateSize,
            modifiedAt: modifiedAt,
            children: children
        )
    }
}
