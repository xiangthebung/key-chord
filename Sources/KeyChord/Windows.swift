// Read-only dictionary problem reports.

import AppKit
import KeyChordCore

// MARK: - Read-only text window

final class TextWindowController: NSWindowController {
    private let textView = NSTextView()

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        textView.frame = scroll.bounds
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        w.contentView?.addSubview(scroll)
        super.init(window: w)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String) {
        textView.string = text
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Rollover probe
