import Foundation
import AppKit

/// Top-level submenu category surfaced under "New File…".
///
/// Each category groups templates the user thinks about together (coding
/// scratch files vs. office documents vs. data) so the contextual menu
/// stays scannable as the catalog grows.
struct FileTemplateCategory {
    let title: String
    let symbolName: String
    let templates: [FileTemplate]
}

/// One entry in the "New File…" submenu.
struct FileTemplate {
    /// Default base file name (without extension) used when creating the file.
    let defaultName: String
    /// File extension *without* the leading dot, e.g. `"json"`.
    let pathExtension: String
    /// Human-readable label shown in the Finder context menu.
    let displayLabel: String
    /// SF Symbol name for the menu item icon.
    let symbolName: String
    /// How to seed the file's contents at creation time.
    let seed: Seed

    enum Seed {
        /// Write the supplied UTF-8 string. Used for plain-text formats.
        case text(String)
        /// Copy a binary template bundled inside the extension's resources.
        /// `resourceName` excludes the file extension.
        case bundleResource(name: String, fileExtension: String)
    }
}

/// Builds the static list of templates and categories surfaced in the
/// Finder Sync menu.
///
/// Each category has its own SF Symbol and order matters – the topmost
/// items are the most-frequently-used formats.
enum FileTemplateFactory {

    static func allCategories() -> [FileTemplateCategory] {
        return [
            FileTemplateCategory(
                title: "Coding",
                symbolName: "chevron.left.forwardslash.chevron.right",
                templates: [
                    FileTemplate(defaultName: "index",
                                 pathExtension: "html",
                                 displayLabel: "HTML (.html)",
                                 symbolName: "doc.richtext",
                                 seed: .text("<!doctype html>\n<html>\n  <head>\n    <meta charset=\"utf-8\">\n    <title></title>\n  </head>\n  <body>\n  </body>\n</html>\n")),
                    FileTemplate(defaultName: "styles",
                                 pathExtension: "css",
                                 displayLabel: "CSS (.css)",
                                 symbolName: "paintbrush",
                                 seed: .text("/* New stylesheet */\n")),
                    FileTemplate(defaultName: "index",
                                 pathExtension: "js",
                                 displayLabel: "JavaScript (.js)",
                                 symbolName: "j.square",
                                 seed: .text("// New JavaScript file\n")),
                    FileTemplate(defaultName: "index",
                                 pathExtension: "ts",
                                 displayLabel: "TypeScript (.ts)",
                                 symbolName: "t.square",
                                 seed: .text("// New TypeScript file\nexport {};\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "py",
                                 displayLabel: "Python (.py)",
                                 symbolName: "p.square",
                                 seed: .text("def main() -> None:\n    pass\n\n\nif __name__ == \"__main__\":\n    main()\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "go",
                                 displayLabel: "Go (.go)",
                                 symbolName: "g.square",
                                 seed: .text("package main\n\nfunc main() {\n}\n")),
                    FileTemplate(defaultName: "Main",
                                 pathExtension: "java",
                                 displayLabel: "Java (.java)",
                                 symbolName: "cup.and.saucer",
                                 seed: .text("public final class Main {\n    public static void main(String[] args) {\n    }\n}\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "rs",
                                 displayLabel: "Rust (.rs)",
                                 symbolName: "gearshape.2",
                                 seed: .text("fn main() {\n}\n")),
                    FileTemplate(defaultName: "Main",
                                 pathExtension: "kt",
                                 displayLabel: "Kotlin (.kt)",
                                 symbolName: "k.square",
                                 seed: .text("fun main() {\n}\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "c",
                                 displayLabel: "C (.c)",
                                 symbolName: "c.square",
                                 seed: .text("#include <stdio.h>\n\nint main(void) {\n    return 0;\n}\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "cpp",
                                 displayLabel: "C++ (.cpp)",
                                 symbolName: "plus.square",
                                 seed: .text("#include <iostream>\n\nint main() {\n    return 0;\n}\n")),
                    FileTemplate(defaultName: "Program",
                                 pathExtension: "cs",
                                 displayLabel: "C# (.cs)",
                                 symbolName: "c.square",
                                 seed: .text("// New C# file\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "swift",
                                 displayLabel: "Swift (.swift)",
                                 symbolName: "swift",
                                 seed: .text("import Foundation\n\n")),
                    FileTemplate(defaultName: "index",
                                 pathExtension: "php",
                                 displayLabel: "PHP (.php)",
                                 symbolName: "p.square",
                                 seed: .text("<?php\n\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "rb",
                                 displayLabel: "Ruby (.rb)",
                                 symbolName: "diamond",
                                 seed: .text("# frozen_string_literal: true\n\n")),
                    FileTemplate(defaultName: "main",
                                 pathExtension: "dart",
                                 displayLabel: "Dart (.dart)",
                                 symbolName: "d.square",
                                 seed: .text("void main() {\n}\n")),
                    FileTemplate(defaultName: "Notes",
                                 pathExtension: "md",
                                 displayLabel: "Markdown (.md)",
                                 symbolName: "doc.plaintext",
                                 seed: .text("# New note\n\n")),
                    FileTemplate(defaultName: "script",
                                 pathExtension: "sh",
                                 displayLabel: "Shell Script (.sh)",
                                 symbolName: "terminal",
                                 seed: .text("#!/usr/bin/env bash\nset -euo pipefail\n\n"))
                ]
            ),
            FileTemplateCategory(
                title: "Microsoft Office",
                symbolName: "doc.fill",
                templates: [
                    FileTemplate(defaultName: "Untitled",
                                 pathExtension: "docx",
                                 displayLabel: "Word Document (.docx)",
                                 symbolName: "doc.richtext",
                                 seed: .bundleResource(name: "Blank", fileExtension: "docx")),
                    FileTemplate(defaultName: "Untitled",
                                 pathExtension: "xlsx",
                                 displayLabel: "Excel Workbook (.xlsx)",
                                 symbolName: "tablecells",
                                 seed: .bundleResource(name: "Blank", fileExtension: "xlsx")),
                    FileTemplate(defaultName: "Untitled",
                                 pathExtension: "rtf",
                                 displayLabel: "Rich Text (.rtf)",
                                 symbolName: "textformat",
                                 seed: .text("{\\rtf1\\ansi\\ansicpg1252\\cocoartf2761\n}\n"))
                ]
            ),
            FileTemplateCategory(
                title: "Data",
                symbolName: "tablecells.badge.ellipsis",
                templates: [
                    FileTemplate(defaultName: "data",
                                 pathExtension: "json",
                                 displayLabel: "JSON (.json)",
                                 symbolName: "curlybraces",
                                 seed: .text("{\n  \n}\n")),
                    FileTemplate(defaultName: "data",
                                 pathExtension: "yaml",
                                 displayLabel: "YAML (.yaml)",
                                 symbolName: "list.bullet.rectangle",
                                 seed: .text("---\n")),
                    FileTemplate(defaultName: "data",
                                 pathExtension: "csv",
                                 displayLabel: "CSV (.csv)",
                                 symbolName: "tablecells",
                                 seed: .text("")),
                    FileTemplate(defaultName: "data",
                                 pathExtension: "tsv",
                                 displayLabel: "TSV (.tsv)",
                                 symbolName: "tablecells",
                                 seed: .text("")),
                    FileTemplate(defaultName: "config",
                                 pathExtension: "toml",
                                 displayLabel: "TOML (.toml)",
                                 symbolName: "gearshape",
                                 seed: .text("# New TOML config\n")),
                    FileTemplate(defaultName: "data",
                                 pathExtension: "xml",
                                 displayLabel: "XML (.xml)",
                                 symbolName: "chevron.left.forwardslash.chevron.right",
                                 seed: .text("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n</root>\n")),
                    FileTemplate(defaultName: "query",
                                 pathExtension: "sql",
                                 displayLabel: "SQL (.sql)",
                                 symbolName: "cylinder",
                                 seed: .text("-- New SQL query\n"))
                ]
            ),
            FileTemplateCategory(
                title: "Project Files",
                symbolName: "shippingbox",
                templates: [
                    FileTemplate(defaultName: "Dockerfile",
                                 pathExtension: "",
                                 displayLabel: "Dockerfile",
                                 symbolName: "shippingbox.fill",
                                 seed: .text("FROM alpine:latest\n\nWORKDIR /app\n")),
                    FileTemplate(defaultName: "Makefile",
                                 pathExtension: "",
                                 displayLabel: "Makefile",
                                 symbolName: "hammer",
                                 seed: .text(".PHONY: build\n\nbuild:\n\t@echo \"Add build commands\"\n")),
                    FileTemplate(defaultName: "",
                                 pathExtension: "env",
                                 displayLabel: "Environment (.env)",
                                 symbolName: "key",
                                 seed: .text("# Environment variables\n")),
                    FileTemplate(defaultName: "",
                                 pathExtension: "gitignore",
                                 displayLabel: "Git Ignore (.gitignore)",
                                 symbolName: "eye.slash",
                                 seed: .text(".DS_Store\nbuild/\n.env\n"))
                ]
            ),
            FileTemplateCategory(
                title: "Text",
                symbolName: "text.alignleft",
                templates: [
                    FileTemplate(defaultName: "Untitled",
                                 pathExtension: "txt",
                                 displayLabel: "Plain Text (.txt)",
                                 symbolName: "doc.text",
                                 seed: .text("")),
                    FileTemplate(defaultName: "README",
                                 pathExtension: "md",
                                 displayLabel: "README (.md)",
                                 symbolName: "doc.plaintext",
                                 seed: .text("# Project name\n\nDescribe the project here.\n"))
                ]
            )
        ]
    }

    /// Flat list of every template, used by `FinderSync` to look up the
    /// template a menu item refers to via its `tag` index.
    static func allTemplates() -> [FileTemplate] {
        return allCategories().flatMap { $0.templates }
    }
}

/// Helpers for creating files from templates with collision-safe naming.
enum FileTemplateWriter {

    enum WriteError: Error, LocalizedError {
        case bundleResourceMissing(String)
        case writeFailed(URL, Error)
        case directoryNotWritable(URL)

        var errorDescription: String? {
            switch self {
            case .bundleResourceMissing(let name):
                return "Augment template \"\(name)\" was missing from the extension bundle."
            case .writeFailed(let url, let underlying):
                return "Could not create \(url.lastPathComponent): \(underlying.localizedDescription)"
            case .directoryNotWritable(let url):
                return "The folder \(url.lastPathComponent) is read-only or you don't have permission to write there."
            }
        }
    }

    /// Writes the supplied template inside `directory`, returning the URL
    /// of the freshly created file. If a file with the desired name
    /// already exists, an incrementing numeric suffix (` 2`, ` 3`, …) is
    /// appended to avoid clobbering existing data.
    ///
    /// We deliberately avoid an `isWritableFile` preflight here. Inside the
    /// Finder Sync extension's sandbox that call returns `false` for many
    /// directories the extension can in fact write to once the security
    /// scope is opened, which previously caused a confusing "permission"
    /// alert before any write was even attempted. Letting the actual
    /// `Data.write` / `copyItem` call run and surfacing its real error is
    /// both more accurate and more helpful to the user.
    static func create(template: FileTemplate,
                       in directory: URL,
                       bundle: Bundle) throws -> URL {
        let target = nonCollidingURL(
            in: directory,
            base: template.defaultName,
            ext: template.pathExtension
        )

        switch template.seed {
        case .text(let body):
            do {
                let data = Data(body.utf8)
                try data.write(to: target, options: [.atomic])
            } catch {
                throw WriteError.writeFailed(target, error)
            }

        case .bundleResource(let name, let ext):
            guard let resourceURL = bundle.url(forResource: name, withExtension: ext) else {
                throw WriteError.bundleResourceMissing("\(name).\(ext)")
            }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: resourceURL, to: target)
            } catch {
                throw WriteError.writeFailed(target, error)
            }
        }

        return target
    }

    /// Returns a URL inside `directory` whose `lastPathComponent` is
    /// `base.ext` if no file with that name exists, otherwise appends
    /// ` 2`, ` 3`, … until an unused name is found. Mirrors how Finder
    /// disambiguates duplicate paste names.
    static func nonCollidingURL(in directory: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        let initial = directory.appendingPathComponent(fileName(base: base, ext: ext, suffix: ""))
        if !fm.fileExists(atPath: initial.path) { return initial }

        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent(
                fileName(base: base, ext: ext, suffix: " \(counter)")
            )
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
            if counter > 9999 {
                return candidate
            }
        }
    }

    private static func fileName(base: String, ext: String, suffix: String) -> String {
        if ext.isEmpty { return "\(base)\(suffix)" }
        if base.isEmpty { return ".\(ext)\(suffix)" }
        return "\(base)\(suffix).\(ext)"
    }
}
