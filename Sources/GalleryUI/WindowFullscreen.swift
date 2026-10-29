import AppKit

/// Native window fullscreen for the viewer. The grid's expand button and the Photo menu use this; the
/// viewer exits it when it closes, so Esc is the one way out the user has to remember.
@MainActor
enum WindowFullscreen {
    private static func target() -> NSWindow? {
        if let key = NSApp.keyWindow, !(key is NSPanel) { return key }
        if let main = NSApp.mainWindow { return main }
        return NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
    }

    /// True when this call actually started the transition; the caller remembers it so a window that was
    /// already fullscreen before the viewer opened is not taken out of it on close.
    @discardableResult
    static func enter() -> Bool {
        guard let window = target(), !window.styleMask.contains(.fullScreen) else { return false }
        window.toggleFullScreen(nil)
        return true
    }

    static func exit() {
        guard let window = target(), window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
}
