// The dictionary reference, with one link back to Practice.

import AppKit
import KeyChordCore
import WebKit

final class ManualWindowController: NSWindowController, WKNavigationDelegate {
    var onPractice: (() -> Void)?
    var onCustomChords: (() -> Void)?
    private let web: WKWebView

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "KeyChord Reference"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 420)
        web = WKWebView(frame: w.contentView!.bounds, configuration: WKWebViewConfiguration())
        web.autoresizingMask = [.width, .height]
        web.setAccessibilityLabel("KeyChord manual")
        w.contentView?.addSubview(web)
        super.init(window: w)
        web.navigationDelegate = self
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(html: String) {
        update(html: html)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func update(html: String) { web.loadHTMLString(html, baseURL: nil) }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.scheme == "keychord", ["practice", "lesson", "course"].contains(url.host ?? "") {
            onPractice?()
        } else if url.scheme == "keychord", url.host == "custom-chords" {
            onCustomChords?()
        } else if url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
    }
}
