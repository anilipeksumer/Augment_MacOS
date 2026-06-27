import XCTest

final class DirectoryTreeBuilderTests: XCTestCase {
    func testIgnoredDirectoryIsSkipped() async throws {
        let root = try makeTempDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)

        let tree = try await DirectoryTreeBuilder().build(at: root)

        let ignored = try XCTUnwrap(tree.children.first { $0.name == "node_modules" })
        if case .directorySkipped(let reason) = ignored.kind {
            XCTAssertEqual(String(describing: reason), String(describing: DirectoryNode.SkipReason.ignoredName))
        } else {
            XCTFail("Expected node_modules to be skipped")
        }
    }

    func testDepthBudgetSkipsNestedDirectory() async throws {
        let root = try makeTempDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)

        let tree = try await DirectoryTreeBuilder(options: DirectoryTreeOptions(maxDepth: 1)).build(at: root)

        let child = try XCTUnwrap(tree.children.first { $0.name == "child" })
        if case .directorySkipped(let reason) = child.kind {
            XCTAssertEqual(String(describing: reason), String(describing: DirectoryNode.SkipReason.depthBudget))
        } else {
            XCTFail("Expected child to be skipped by depth budget")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AugmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
