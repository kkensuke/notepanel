import AppKit
import NotepanelCore

/// Where ⌃⌘M puts the panel, and the default place for each display, which Settings shows and sets.
@MainActor
final class PanelPlacement {
    private let panel: NSWindow
    /// The panel's size before a saved frame replaces it, which ⌃⌘M goes back to.
    var defaultSize = NSSize.zero
    /// Where ⌃⌘M found the panel and where it put it, so a second press, before the panel moves
    /// or changes size, takes it back. The note's text size goes back with it; nil if it was never set.
    private var frameBeforeDefault: NSRect?
    private var defaultFrame: NSRect?
    private var fontSizeBeforeDefault: Double?

    init(panel: NSWindow) {
        self.panel = panel
    }

    /// ⌃⌘M: the default frame and text size set in Settings for the display with the pointer, or
    /// else the panel's first size, centered there, with the default text size. Using the pointer's
    /// display brings the panel to the display in use. Pressed again before the panel moves or
    /// changes size, it goes back to where it was, with the text size it had.
    func toggleDefaultFrame() {
        let defaults = UserDefaults.standard
        if let previous = frameBeforeDefault, panel.frame == defaultFrame {
            panel.setFrame(previous, display: true)
            frameBeforeDefault = nil
            defaults.set(fontSizeBeforeDefault, forKey: Prefs.Key.fontSize)
            return
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        else { return }
        frameBeforeDefault = panel.frame
        fontSizeBeforeDefault = defaults.object(forKey: Prefs.Key.fontSize) as? Double
        let key = screen.displayKey
        let saved = key.flatMap { Prefs.defaultFrame(for: $0) }
        panel.setFrame(
            placeOnDisplay(saved: saved, size: defaultSize, display: screen.frame, visible: screen.visibleFrame),
            display: true)
        defaultFrame = panel.frame
        defaults.set(key.map { Prefs.defaultFontSize(for: $0) } ?? Prefs.defaultFontSize, forKey: Prefs.Key.fontSize)
    }

    /// The note's text size ⌘0 sets: the default for the display the panel is on, as ⌘0 doesn't
    /// move the panel.
    var defaultFontSize: Double {
        panelScreen?.displayKey.map { Prefs.defaultFontSize(for: $0) } ?? Prefs.defaultFontSize
    }

    /// The display the panel is on, as Settings shows it, and its default for ⌃⌘M.
    func defaultPlace() -> DefaultPlace? {
        guard let screen = panelScreen, let key = screen.displayKey else { return nil }
        let saved = Prefs.defaultFrame(for: key)
        let builtIn = screen.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        let display = screen.frame
        let frame = placeOnDisplay(saved: saved, size: defaultSize, display: display, visible: screen.visibleFrame)
        return DefaultPlace(
            display: screen.localizedName, builtIn: builtIn, displaySize: display.size,
            menuBar: display.maxY - screen.visibleFrame.maxY,
            // AppKit's y goes up from the bottom; screen positions are usually shown from the top-left.
            frame: NSRect(
                x: frame.minX - display.minX, y: display.maxY - frame.maxY, width: frame.width, height: frame.height),
            fontSize: Prefs.defaultFontSize(for: key),
            custom: saved != nil)
    }

    /// Settings' Use Current: on the panel's display, ⌃⌘M will put the panel where it is now, with
    /// the note's text at the size it has now.
    func useCurrentFrameAsDefault() {
        guard let screen = panelScreen, let key = screen.displayKey else { return }
        let fontSize = UserDefaults.standard.object(forKey: Prefs.Key.fontSize) as? Double ?? Prefs.defaultFontSize
        Prefs.setDefaultFrame(
            panel.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), fontSize: fontSize, for: key)
    }

    /// Settings' Reset: on the panel's display, ⌃⌘M will use the first size, centered, and the
    /// default text size.
    func useStandardFrame() {
        guard let key = panelScreen?.displayKey else { return }
        Prefs.setDefaultFrame(nil, fontSize: nil, for: key)
    }

    /// The display most of the panel is on. Worked out from the frame, as `NSWindow.screen` may be
    /// nil while the panel is hidden.
    private var panelScreen: NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.frame.intersection(panel.frame)
            return shared.width * shared.height
        }
        return NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The display's UUID, which lasts across restarts and reconnections, unlike its ID. Mirrored
    /// displays all go by the one they mirror, whichever of them this screen stands for.
    var displayKey: String? {
        guard let id = displayID else { return nil }
        let mirrored = CGDisplayMirrorsDisplay(id)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(mirrored == kCGNullDirectDisplay ? id : mirrored)
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }
}
