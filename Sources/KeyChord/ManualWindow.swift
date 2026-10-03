// "Learn KeyChord": the manual (KeyChordCore's Manual page) in a web view. Lesson links open the lesson in the
// Typing Guide; other links open in the browser.

import AppKit
import KeyChordCore
import WebKit

final class ManualWindowController: NSWindowController, WKNavigationDelegate {
    /// Called with a lesson index when a "Practice" link is clicked.
    var onLesson: ((Int) -> Void)?
    /// Called when a link to the course is clicked.
    var onCourse: (() -> Void)?
    private let web: WKWebView

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 820),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Learn KeyChord"
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
        web.loadHTMLString(html, baseURL: nil)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if url.scheme == "keychord", url.host == "lesson", let n = Int(url.lastPathComponent) {
            onLesson?(n)
        } else if url.scheme == "keychord", url.host == "course" {
            onCourse?()
        } else if url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
        }
    }
}
