import Cocoa
import QuickLookUI
import UniformTypeIdentifiers
import WebKit

/// View-based Quick Look preview for folders. Uses `WKWebView` so `file://`
/// navigations can be handled natively: plain HTML previews typically block
/// those links, which is why “Finder’da göster” and file taps did nothing.
///
/// - **Dosyalar:** `/usr/bin/qlmanage -p` ile sistem Quick Look penceresi.
/// - **Klasörler:** Finder’da klasörü seçip öne getirir (`activateFileViewerSelecting`).
@objc(FolderPreviewViewController)
final class FolderPreviewViewController: NSViewController, QLPreviewingController {

    private var webView: WKWebView!
    private var scopedFolderURL: URL?
    private var isSecurityScoped = false
    private var previewTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        // Layer-backing can composite poorly with WKWebView inside Quick Look; keep default false.
        container.wantsLayer = false
        view = container

        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = false

        let wv = WKWebView(frame: container.bounds, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        
        // Transparency support
        wv.setValue(false, forKey: "drawsBackground")

        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        webView = wv
    }

    func preparePreviewOfFile(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        _ = view

        let folderURL = url.standardizedFileURL
        previewTask?.cancel()
        stopSecurityScope()

        isSecurityScoped = folderURL.startAccessingSecurityScopedResource()
        scopedFolderURL = folderURL
        previewTask = Task { [weak self] in
            guard let self else { return }
            
            let enabled = AppGroup.preferencesBool(forKey: AppGroupKey.folderQuickLookEnabled)
            let showWarning = AppGroup.preferencesBool(forKey: AppGroupKey.folderQuickLookShowWarning)
            
            if !enabled {
                if showWarning {
                    let meta = self.getFolderMetadata(for: folderURL)
                    let html = Self.featureOffHTML(for: folderURL, meta: meta)
                    await MainActor.run {
                        self.webView.loadHTMLString(html, baseURL: nil)
                        completionHandler(nil)
                    }
                } else {
                    await MainActor.run {
                        completionHandler(NSError(domain: "com.apple.QuickLookUI", code: -1, userInfo: nil))
                    }
                }
                return
            }

            let html: String
            if !Self.isFolderURL(folderURL) {
                html = Self.errorHTML(
                    title: "Not a folder",
                    message: "Augment's folder preview only works on directories."
                )
            } else {
                let builder = DirectoryTreeBuilder()
                do {
                    let tree = try await builder.build(at: folderURL)
                    html = DirectoryTreeFormatter.renderHTML(root: tree, originalURL: folderURL)
                } catch is CancellationError {
                    html = Self.errorHTML(
                        title: "Preview cancelled",
                        message: "The folder preview was dismissed before it finished."
                    )
                } catch {
                    html = Self.errorHTML(
                        title: "Could not preview folder",
                        message: error.localizedDescription
                    )
                }
            }

            await MainActor.run {
                // `baseURL` is only for resolving relative URLs; a file URL here can confuse sandboxed WebKit.
                // Folder paths in links are absolute `file://` from DirectoryTreeFormatter.
                self.webView.loadHTMLString(html, baseURL: nil)
                completionHandler(nil)
            }
        }
    }

    deinit {
        previewTask?.cancel()
        stopSecurityScope()
    }

    private func getFolderMetadata(for url: URL) -> (size: String, count: String, date: String, iconBase64: String) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 256, height: 256)
        
        let iconData: String
        if let tiff = icon.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            iconData = png.base64EncodedString()
        } else {
            iconData = ""
        }
        
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let date = values?.contentModificationDate ?? Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        dateFormatter.locale = Locale(identifier: "tr_TR")
        let dateStr = "Son değişiklik tarihi " + dateFormatter.string(from: date)
        
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        let countStr = "\(items) öğe"
        
        // Getting folder size quickly without crawling is impossible, so we'll just show the item count
        // or a placeholder if we don't want to block the thread.
        return (size: "", count: countStr, date: dateStr, iconBase64: iconData)
    }

    private func stopSecurityScope() {
        if isSecurityScoped, let folder = scopedFolderURL {
            folder.stopAccessingSecurityScopedResource()
        }
        isSecurityScoped = false
        scopedFolderURL = nil
    }

    // MARK: - HTML fragments (same strings as former data-based provider)

    private static func featureOffHTML(for url: URL, meta: (size: String, count: String, date: String, iconBase64: String)) -> String {
        let accent = "#007aff"
        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
                    background: transparent;
                    color: white;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    height: 100vh;
                    margin: 0;
                    -webkit-font-smoothing: antialiased;
                    overflow: hidden;
                }
                .mimic-container {
                    display: flex;
                    align-items: center;
                    gap: 40px;
                    padding: 40px;
                    max-width: 800px;
                }
                .folder-icon {
                    width: 220px;
                    height: 220px;
                    object-fit: contain;
                    filter: drop-shadow(0 10px 20px rgba(0,0,0,0.3));
                }
                .info {
                    display: flex;
                    flex-direction: column;
                    gap: 4px;
                }
                h1 { 
                    margin: 0; 
                    font-weight: 700; 
                    font-size: 34px; 
                    letter-spacing: -0.02em; 
                    color: white;
                }
                .meta { 
                    margin: 4px 0 0; 
                    color: rgba(255,255,255,0.6); 
                    font-size: 17px; 
                    font-weight: 400; 
                }
                .date { 
                    margin: 0; 
                    color: rgba(255,255,255,0.45); 
                    font-size: 15px; 
                }
                .augment-warning {
                    margin-top: 32px;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    background: rgba(255, 255, 255, 0.1);
                    padding: 8px 14px;
                    border-radius: 10px;
                    font-size: 13px;
                    backdrop-filter: blur(20px);
                    -webkit-backdrop-filter: blur(20px);
                    border: 1px solid rgba(255,255,255,0.1);
                    color: rgba(255,255,255,0.9);
                    width: fit-content;
                }
                .accent-btn { 
                    color: \(accent); 
                    font-weight: 600; 
                    text-decoration: none;
                    margin-left: 4px;
                }
                .accent-btn:hover { text-decoration: underline; }
                .aug-icon { font-weight: 800; color: \(accent); }
            </style>
        </head>
        <body>
            <div class="mimic-container">
                <img class="folder-icon" src="data:image/png;base64,\(meta.iconBase64)" alt="">
                <div class="info">
                    <h1>\(escape(url.lastPathComponent))</h1>
                    <p class="meta">\(meta.count)</p>
                    <p class="date">\(meta.date)</p>
                    
                    <div class="augment-warning">
                        <span class="aug-icon">Augment</span> 
                        <span>Hiyerarşi önizlemesi kapalı.</span>
                        <a class="accent-btn" href="augment://settings/finder">Ayarlardan Aç</a>
                    </div>
                </div>
            </div>
        </body>
        </html>
        """
    }

    private static func errorHTML(title: String, message: String) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:24px;color:#1d1d1f;">
            <h2 style="margin:0 0 6px;font-weight:600;font-size:15px;">\(escape(title))</h2>
            <p style="margin:0;color:#6e6e73;font-size:12px;">\(escape(message))</p>
        </body>
        </html>
        """
    }

    private static func isFolderURL(_ url: URL) -> Bool {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return true
        }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func escape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    // MARK: - Actions

    private func handleFileURL(_ url: URL) {
        let standardized = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDir) else {
            return
        }

        if isDir.boolValue {
            revealInFinder(standardized)
        } else {
            openSystemQuickLook(forFileAt: standardized)
        }
    }

    private func revealInFinder(_ url: URL) {
        do {
            try FinderRevealBridge.enqueue(.init(filePath: url.path))
            AppGroup.setSuiteValue(
                kCFBooleanTrue,
                forKey: AppGroupKey.pendingFinderBridgeHostLaunch
            )
            if let wakeURL = URL(string: "augment://finder-reveal") {
                NSWorkspace.shared.open(wakeURL)
            }
        } catch {
            NSLog("Augment Quick Look: reveal bridge failed - %@", error.localizedDescription)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openSystemQuickLook(forFileAt url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - WKNavigationDelegate

extension FolderPreviewViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Handle custom URL schemes (e.g. augment://settings/finder)
        if !url.isFileURL && url.scheme != "about" && url.scheme != "data" {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
            return
        }

        guard url.isFileURL else {
            decisionHandler(.allow)
            return
        }

        // Embedded WKWebView often reports link taps as `.other` instead of `.linkActivated`.
        switch navigationAction.navigationType {
        case .linkActivated:
            decisionHandler(.cancel)
            handleFileURL(url)
        case .other:
            guard navigationAction.sourceFrame.isMainFrame else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            handleFileURL(url)
        default:
            decisionHandler(.allow)
        }
    }
}

// MARK: - WKUIDelegate

extension FolderPreviewViewController: WKUIDelegate {

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if url.isFileURL {
                handleFileURL(url)
            } else if url.scheme != "about" && url.scheme != "data" {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }
}
