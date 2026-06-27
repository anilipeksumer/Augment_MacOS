import XCTest

final class FileTemplateFactoryTests: XCTestCase {
    func testNonCollidingURLUsesFinderStyleNumericSuffix() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("Untitled.txt"))
        try Data().write(to: dir.appendingPathComponent("Untitled 2.txt"))

        let url = FileTemplateWriter.nonCollidingURL(in: dir, base: "Untitled", ext: "txt")

        XCTAssertEqual(url.lastPathComponent, "Untitled 3.txt")
    }

    func testTextTemplateCreateWritesSeedBody() throws {
        let dir = try makeTempDirectory()
        let template = FileTemplate(
            defaultName: "Notes",
            pathExtension: "md",
            displayLabel: "Markdown",
            symbolName: "doc",
            seed: .text("# Hello\n")
        )

        let url = try FileTemplateWriter.create(template: template, in: dir, bundle: .main)
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(url.lastPathComponent, "Notes.md")
        XCTAssertEqual(text, "# Hello\n")
    }

    func testExtensionlessAndHiddenTemplateNames() throws {
        let dir = try makeTempDirectory()

        let dockerfile = FileTemplateWriter.nonCollidingURL(in: dir, base: "Dockerfile", ext: "")
        let environment = FileTemplateWriter.nonCollidingURL(in: dir, base: "", ext: "env")

        XCTAssertEqual(dockerfile.lastPathComponent, "Dockerfile")
        XCTAssertEqual(environment.lastPathComponent, ".env")
    }

    func testExtensionlessCollisionUsesNumericSuffixWithoutTrailingDot() throws {
        let dir = try makeTempDirectory()
        try Data().write(to: dir.appendingPathComponent("Makefile"))

        let url = FileTemplateWriter.nonCollidingURL(in: dir, base: "Makefile", ext: "")

        XCTAssertEqual(url.lastPathComponent, "Makefile 2")
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
