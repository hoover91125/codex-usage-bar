#if DEBUG
import AppKit
import SwiftUI

/// Temporary harness: renders the menu popover and the settings window to PNGs
/// so their layout can be checked without Screen Recording permission.
@MainActor
enum RenderPreview {
    static func run(directory: String) -> Never {
        let store = UsageStore()
        // The persisted cache is loaded synchronously in `init`, so there is
        // already real data to lay out; give the install probe a moment so the
        // sections render as present rather than "not installed".
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, store.snapshots.isEmpty || store.isLoading {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        // The store writes every preference straight through to UserDefaults,
        // so the mode is put back before exiting — a preview run must not
        // leave the user's own setting flipped.
        let originalMode = store.usageDisplayMode
        defer { store.usageDisplayMode = originalMode }

        for mode in UsageDisplayMode.allCases {
            store.usageDisplayMode = mode
            write(UsagePopover(store: store, onShowSettings: {}), to: "\(directory)/popover-\(mode.rawValue).png")
            write(UsagePopover(store: store, onShowSettings: {}), to: "\(directory)/popover-\(mode.rawValue)-dark.png", dark: true)
            // The settings window's title bar is part of what needs checking
            // (a long title truncates against the toolbar), so it is captured
            // once in a real titled window rather than only as bare content.
            writeChrome(
                SettingsView(store: store, selection: .display),
                title: store.tr("settings_window_title"),
                to: "\(directory)/settings-window-\(mode.rawValue).png"
            )

            for tab in SettingsView.Tab.allCases {
                write(
                    SettingsView(store: store, selection: tab),
                    to: "\(directory)/settings-\(mode.rawValue)-\(tab).png"
                )
            }
        }
        exit(EXIT_SUCCESS)
    }

    /// Renders a view inside a real titled window and captures the whole
    /// window frame, title bar and toolbar included.
    private static func writeChrome(_ view: some View, title: String, to path: String) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: settingsWindowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: view)
        window.setIsVisible(true)
        window.displayIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.6))

        // The theme frame is the content view's superview; it owns the title
        // bar, so capturing the content view alone would miss the thing under
        // test.
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print("wrote \(path) \(Int(frame.bounds.width))x\(Int(frame.bounds.height))")
    }

    private static func write(_ view: some View, to path: String, dark: Bool = false) {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        // Text only rasterizes once the view is in a window with a real
        // appearance and backing scale, so it is hosted in an offscreen one.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? .black : .white
        window.contentView = hosting
        window.displayIfNeeded()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.4))

        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(Int(size.width))x\(Int(size.height))")
    }
}
#endif
