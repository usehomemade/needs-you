import CoreGraphics

/// Where the status island's panel sits (HM-1410). Pure so it can be tested: the
/// app passes the screen's frame, the notch's centre and the backing scale.
///
/// Every edge lands on a whole device pixel, computed from the screen each time,
/// so the pill never sits a pixel or two off from one showing to the next.
public enum IslandLayout {
    /// Rounds `v` to the nearest device pixel at `scale` (2 on Retina).
    public static func pixel(_ v: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(1, scale)
        return (v * s).rounded() / s
    }

    /// The panel frame: `size` centred on `centerX`, its top flush with the top of `screen`.
    public static func panelFrame(screen: CGRect, centerX: CGFloat, size: CGSize, scale: CGFloat) -> CGRect {
        let w = pixel(size.width, scale: scale), h = pixel(size.height, scale: scale)
        let top = pixel(screen.maxY, scale: scale)
        let x = pixel(centerX - w / 2, scale: scale)
        return CGRect(x: x, y: top - h, width: w, height: h)
    }

    /// The notch's width and centre from the menu bar areas left and right of it.
    /// Nil when either side is missing (no notch).
    public static func notch(screen: CGRect, leftArea: CGRect?, rightArea: CGRect?, scale: CGFloat) -> (width: CGFloat, centerX: CGFloat)? {
        // Only the areas' widths are used: their origins are not in the same space on every screen.
        guard let l = leftArea, let r = rightArea else { return nil }
        let left = pixel(screen.minX + l.width, scale: scale), right = pixel(screen.maxX - r.width, scale: scale)
        let w = max(120, right - left)
        return (w, pixel((left + right) / 2, scale: scale))
    }
}
