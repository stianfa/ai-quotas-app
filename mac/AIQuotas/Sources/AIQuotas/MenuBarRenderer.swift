import AppKit

/// Draws the whole menu bar readout — labels, gradient bars, percentages — into a
/// single NSImage.
///
/// It all has to be one image because NSStatusItem offers only one image slot plus
/// a title; there is no way to interleave several drawn bars with text otherwise.
enum MenuBarRenderer {

    struct Entry {
        let tag: String          // e.g. "Claude" — empty to omit the label
        let percent: Double?     // nil renders an em dash instead of a bar
        var reset: String?       // compact countdown, e.g. "6d" — nil to omit
        /// A second, longer-horizon value sharing the same bar: drawn as a faint
        /// full-height fill, with `percent` as a thinner solid fill inside it.
        var background: Double?

        init(tag: String, percent: Double?, reset: String? = nil, background: Double? = nil) {
            self.tag = tag
            self.percent = percent
            self.reset = reset
            self.background = background
        }
    }

    /// User-tunable geometry, set in Settings.
    struct Style {
        var barWidth: CGFloat = 42
        var barHeight: CGFloat = 7
        var showPercentText: Bool = true
        var showReset: Bool = true
        /// Empty space padded onto the right of the image. Since macOS packs status
        /// items right-to-left from the clock and offers no positioning API, padding
        /// here is the only way to shift the visible content leftward.
        var trailingInset: CGFloat = 10
    }

    /// The macOS menu bar is 22pt tall, so anything drawn beyond this gets clipped
    /// by the system regardless of what we ask for.
    private static let maxHeight: CGFloat = 22
    private static let minHeight: CGFloat = 16
    private static let gapAfterTag: CGFloat = 4
    private static let gapAfterBar: CGFloat = 4
    private static let gapAfterReset: CGFloat = 4
    /// Separation between the two provider groups — deliberately larger than any
    /// gap inside a group, so each reads as one unit rather than a run of text.
    private static let gapBetweenEntries: CGFloat = 20
    /// Breathing room at the left end. The image otherwise butts straight up against
    /// whatever menu bar item sits beside it. macOS adds only a couple of points of
    /// its own, so this needs to be generous to read as separation.
    private static let leadingInset: CGFloat = 10

    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: 11, weight: .medium
    )

    /// Green → amber → red across 0–100%. The colour tracks the *fill level*, so a
    /// bar's own tip tells you the severity even at a glance.
    private static func color(for fraction: Double) -> NSColor {
        let f = max(0, min(1, fraction))
        // Hue 0.33 (green) → 0.0 (red), easing through amber around 0.6–0.8.
        let hue = 0.33 * (1.0 - pow(f, 1.35))
        return NSColor(hue: hue, saturation: 0.85, brightness: 0.85, alpha: 1.0)
    }

    private static func textAttributes() -> [NSAttributedString.Key: Any] {
        // labelColor is dynamic, so the text stays legible in both menu bar themes.
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    private static func widthOf(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: textAttributes()).width
    }

    /// Dimmer + slightly smaller than the percentage, so the countdown reads as
    /// secondary information rather than competing with the number.
    private static let resetFont = NSFont.monospacedDigitSystemFont(
        ofSize: 10, weight: .regular
    )

    private static func widthOfReset(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: resetFont]).width
    }

    /// Fixed width for the countdown so bars stay aligned as the value changes.
    /// "23h" is the widest realistic case (days/hours/minutes are ≤ 2 digits).
    private static var resetBoxWidth: CGFloat { widthOfReset("23h") }

    /// Fixed box for the percentage so the layout doesn't shift as the number
    /// changes. Two values read "34/81%", so they reserve room for both.
    private static func percentBoxWidth(_ e: Entry) -> CGFloat {
        widthOf(e.background == nil ? "100%" : "100/100%")
    }

    private static func percentLabel(_ e: Entry, _ pct: Double) -> String {
        guard let bg = e.background else { return "\(Int(pct.rounded()))%" }
        return "\(Int(pct.rounded()))/\(Int(bg.rounded()))%"
    }

    /// Opacity of the background fill — dim enough that the solid inner fill
    /// stays the obvious one, but its own colour still shows the level.
    private static let backgroundAlpha: CGFloat = 0.35
    /// The inner fill's share of the bar's height when a background is drawn.
    private static let innerHeightRatio: CGFloat = 0.5

    /// Fill: one fixed green→red ramp spanning the *whole* track, revealed only up
    /// to the current level. Scaling the ramp to the fill instead would squeeze
    /// green→red into a few pixels at low percentages, so every small value would
    /// look the same muddy colour.
    private static func drawFill(x: CGFloat, y: CGFloat, trackWidth: CGFloat,
                                 height: CGFloat, fraction: Double) {
        guard fraction > 0 else { return }
        let radius = height / 2
        // Floor the width so a low value is still a visible sliver rather than a
        // dot lost against the track.
        let fillWidth = max(height + 2, trackWidth * fraction)
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: height)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).addClip()
        let gradient = NSGradient(colors: [
            color(for: 0.0),    // green at empty
            color(for: 0.55),
            color(for: 0.8),    // amber
            color(for: 1.0),    // red at full
        ])
        gradient?.draw(in: NSRect(x: x, y: y, width: trackWidth, height: height), angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    static func image(for entries: [Entry], style: Style = Style()) -> NSImage? {
        guard !entries.isEmpty else { return nil }
        let barWidth = max(12, style.barWidth)
        // Cap at the menu bar's own height — taller would just be clipped.
        let barHeight = max(3, min(style.barHeight, maxHeight))
        // Grow the canvas to fit a tall bar, but never below the text's needs.
        let height = max(minHeight, barHeight + 2)

        // Dynamic colours (labelColor, tertiaryLabelColor) resolve against whatever
        // appearance is current when the drawing block runs. Pin it to the menu
        // bar's own appearance so the text and track contrast correctly in both
        // light and dark themes instead of defaulting to one of them.
        let appearance = NSApp.effectiveAppearance

        // Measure first so the image is exactly wide enough — the status item is
        // variableLength, so a too-wide image would leave dead space.
        var total: CGFloat = leadingInset + max(0, style.trailingInset)
        for (i, e) in entries.enumerated() {
            if !e.tag.isEmpty { total += widthOf(e.tag) + gapAfterTag }
            if e.percent == nil {
                total += widthOf("—")
            } else {
                // Order: [tag] [reset] [bar] [percent]
                if style.showReset, e.reset != nil {
                    total += resetBoxWidth + gapAfterReset
                }
                total += barWidth
                if style.showPercentText { total += gapAfterBar + percentBoxWidth(e) }
            }
            if i < entries.count - 1 { total += gapBetweenEntries }
        }

        let size = NSSize(width: ceil(total), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = leadingInset
            var attrs = textAttributes()
            var secondaryColor = NSColor.secondaryLabelColor
            // Resolve the dynamic text colours against the menu bar's appearance.
            appearance.performAsCurrentDrawingAppearance {
                attrs[.foregroundColor] = NSColor.labelColor.usingColorSpace(.sRGB)
                    ?? NSColor.labelColor
                secondaryColor = NSColor.secondaryLabelColor.usingColorSpace(.sRGB)
                    ?? NSColor.secondaryLabelColor
            }

            for (i, e) in entries.enumerated() {
                if !e.tag.isEmpty {
                    let tag = e.tag as NSString
                    let tagSize = tag.size(withAttributes: attrs)
                    tag.draw(at: NSPoint(x: x, y: (height - tagSize.height) / 2),
                             withAttributes: attrs)
                    x += tagSize.width + gapAfterTag
                }

                guard let pct = e.percent else {
                    let dash = "—" as NSString
                    let dSize = dash.size(withAttributes: attrs)
                    dash.draw(at: NSPoint(x: x, y: (height - dSize.height) / 2), withAttributes: attrs)
                    x += dSize.width
                    // Match the measuring pass: no trailing gap after the last entry.
                    if i < entries.count - 1 { x += gapBetweenEntries }
                    continue
                }

                // Countdown sits between the label and the bar, right-aligned in a
                // fixed box so a "12m" and a "6d" still start their bars at the
                // same offset instead of the bars stepping in and out.
                if style.showReset, let r = e.reset {
                    let reset = r as NSString
                    let rSize = reset.size(withAttributes: [.font: resetFont])
                    let boxWidth = resetBoxWidth
                    reset.draw(at: NSPoint(x: x + boxWidth - rSize.width,
                                           y: (height - rSize.height) / 2),
                               withAttributes: [
                                   .font: resetFont,
                                   .foregroundColor: secondaryColor,
                               ])
                    x += boxWidth + gapAfterReset
                }

                let fraction = max(0, min(1, pct / 100))

                // Track
                let trackRect = NSRect(x: x, y: (height - barHeight) / 2,
                                       width: barWidth, height: barHeight)
                let radius = barHeight / 2
                var trackColor = NSColor.tertiaryLabelColor
                appearance.performAsCurrentDrawingAppearance {
                    trackColor = NSColor.tertiaryLabelColor.usingColorSpace(.sRGB)
                        ?? NSColor.tertiaryLabelColor
                }
                trackColor.setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: radius, yRadius: radius).fill()

                if let bg = e.background {
                    // Faint, full height, behind everything else.
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current?.cgContext.setAlpha(backgroundAlpha)
                    drawFill(x: x, y: trackRect.minY, trackWidth: barWidth,
                             height: barHeight, fraction: max(0, min(1, bg / 100)))
                    NSGraphicsContext.restoreGraphicsState()

                    // Solid and thinner, centred inside the background fill.
                    let inner = max(2, (barHeight * innerHeightRatio).rounded())
                    drawFill(x: x, y: (height - inner) / 2, trackWidth: barWidth,
                             height: inner, fraction: fraction)
                } else {
                    drawFill(x: x, y: trackRect.minY, trackWidth: barWidth,
                             height: barHeight, fraction: fraction)
                }
                x += barWidth

                if style.showPercentText {
                    x += gapAfterBar
                    // Right-aligned in a fixed box so the layout doesn't shift as
                    // the number grows or shrinks.
                    let label = percentLabel(e, pct) as NSString
                    let boxWidth = percentBoxWidth(e)
                    let lSize = label.size(withAttributes: attrs)
                    label.draw(at: NSPoint(x: x + boxWidth - lSize.width,
                                           y: (height - lSize.height) / 2),
                               withAttributes: attrs)
                    x += boxWidth
                }

                if i < entries.count - 1 { x += gapBetweenEntries }
            }
            return true
        }

        // Not a template: template mode would flatten everything to one colour and
        // discard the gradient entirely.
        image.isTemplate = false
        return image
    }
}
