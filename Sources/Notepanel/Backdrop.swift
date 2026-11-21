import AppKit

/// tinycast's background, under a page: glass (a blur before macOS 26) under a scrim. It runs under
/// the title bar too, while the page starts below the title bar, where it was before.
@MainActor
final class Backdrop {
    /// The backdrop with the page over it, to be a window's content view.
    let view = NSView()
    private let glass: NSView
    private let scrim = NSBox()

    init(behind page: NSView, cornerRadius: CGFloat = 0) {
        glass = Self.makeGlass(cornerRadius: cornerRadius)
        scrim.boxType = .custom
        scrim.titlePosition = .noTitle
        scrim.borderWidth = 0
        scrim.cornerRadius = cornerRadius
        scrim.fillColor = Self.scrimColor(solid: 0)
        for backdrop in [glass, scrim] {
            backdrop.frame = view.bounds
            backdrop.autoresizingMask = [.width, .height]
            view.addSubview(backdrop)
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// The background's opacity; the text keeps its own. 0 leaves nothing behind the text, the
    /// default is tinycast's background, and 1 is solid. Up to the default, the glass and the
    /// scrim fade in together; past it, the scrim gets more opaque.
    func setOpacity(_ opacity: Double) {
        let middle = Prefs.defaultBackgroundOpacity
        let fade = CGFloat(min(1, opacity / middle))
        glass.alphaValue = fade
        scrim.alphaValue = fade
        scrim.fillColor = Self.scrimColor(solid: max(0, (opacity - middle) / (1 - middle)))
    }

    private static func makeGlass(cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            if cornerRadius > 0 { glass.cornerRadius = cornerRadius }
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        // The app is never active, so the blur would otherwise always look inactive.
        blur.state = .active
        if cornerRadius > 0 {
            // A rounded square, stretched between its corners.
            let size = 2 * cornerRadius + 1
            let mask = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
            mask.resizingMode = .stretch
            blur.maskImage = mask
        }
        return blur
    }

    /// tinycast's scrim is black at 40% in dark mode and white at 55% in light mode. `solid`,
    /// from 0 to 1, takes it from there to fully opaque.
    private static func scrimColor(solid: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let alpha = dark ? 0.4 : 0.55
            return (dark ? NSColor.black : .white).withAlphaComponent(CGFloat(alpha + (1 - alpha) * solid))
        }
    }
}
