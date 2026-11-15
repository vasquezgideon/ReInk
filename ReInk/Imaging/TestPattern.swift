import UIKit

/// Calibration image: a solid corner marker per corner, color bars with
/// labels, an up arrow and fine line patches. Where the black square lands
/// tells us which rotate/mirror flags the case needs.
enum TestPattern {
    static func indices(width: Int, height: Int) -> [UInt8] {
        let W = CGFloat(width)
        let H = CGFloat(height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: format)
        let black = UIColor.black
        let white = UIColor.white
        let yellow = UIColor(red: 1, green: 0.85, blue: 0, alpha: 1)
        let red = UIColor(red: 0.85, green: 0.08, blue: 0.08, alpha: 1)

        let image = renderer.image { rc in
            let ctx = rc.cgContext
            ctx.setAllowsAntialiasing(false)
            white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

            let s = (min(W, H) / 5).rounded()
            black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            red.setFill()
            ctx.fill(CGRect(x: W - s, y: 0, width: s, height: s))
            yellow.setFill()
            ctx.fill(CGRect(x: 0, y: H - s, width: s, height: s))
            // Bottom-right: checkerboard.
            let cell = max(4, (s / 6).rounded())
            var yy = H - s
            var row = 0
            while yy < H {
                var xx = W - s
                var col = 0
                while xx < W {
                    ((row + col) % 2 == 0 ? black : white).setFill()
                    ctx.fill(CGRect(x: xx, y: yy, width: cell, height: cell))
                    xx += cell
                    col += 1
                }
                yy += cell
                row += 1
            }

            // Arrow pointing up.
            let cx = W / 2
            let top = s * 0.6
            let arrowW = W * 0.28
            let path = UIBezierPath()
            path.move(to: CGPoint(x: cx, y: top))
            path.addLine(to: CGPoint(x: cx + arrowW / 2, y: top + arrowW * 0.6))
            path.addLine(to: CGPoint(x: cx + arrowW / 6, y: top + arrowW * 0.6))
            path.addLine(to: CGPoint(x: cx + arrowW / 6, y: top + arrowW * 1.3))
            path.addLine(to: CGPoint(x: cx - arrowW / 6, y: top + arrowW * 1.3))
            path.addLine(to: CGPoint(x: cx - arrowW / 6, y: top + arrowW * 0.6))
            path.addLine(to: CGPoint(x: cx - arrowW / 2, y: top + arrowW * 0.6))
            path.close()
            black.setFill()
            path.fill()

            // Labels.
            let titleFont = UIFont.systemFont(ofSize: max(18, W / 14), weight: .heavy)
            let bodyFont = UIFont.systemFont(ofSize: max(12, W / 26), weight: .bold)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let title = NSAttributedString(string: "TOP · ReInk", attributes: [.font: titleFont, .foregroundColor: black, .paragraphStyle: para])
            title.draw(in: CGRect(x: 0, y: top + arrowW * 1.35, width: W, height: titleFont.lineHeight * 1.2))
            let size = NSAttributedString(string: "\(width) × \(height)  ·  black square = top-left", attributes: [.font: bodyFont, .foregroundColor: black, .paragraphStyle: para])
            size.draw(in: CGRect(x: 0, y: top + arrowW * 1.35 + titleFont.lineHeight * 1.2, width: W, height: bodyFont.lineHeight * 1.3))

            // Color bars.
            let barTop = H * 0.52
            let barH = H * 0.16
            let barW = (W - 40) / 4
            let bars: [(UIColor, String)] = [(black, "B"), (white, "W"), (yellow, "Y"), (red, "R")]
            for (i, bar) in bars.enumerated() {
                let rect = CGRect(x: 20 + CGFloat(i) * barW, y: barTop, width: barW, height: barH)
                bar.0.setFill()
                ctx.fill(rect)
                black.setStroke()
                ctx.setLineWidth(2)
                ctx.stroke(rect)
                let label = NSAttributedString(string: bar.1, attributes: [.font: titleFont, .foregroundColor: black, .paragraphStyle: para])
                label.draw(in: CGRect(x: rect.minX, y: rect.maxY + 4, width: barW, height: titleFont.lineHeight * 1.2))
            }

            // Fine line patches: 1 px vertical lines (left) and horizontal lines (right).
            let patchTop = barTop + barH + titleFont.lineHeight * 1.4
            let patchH = max(0, H - s - patchTop - 12)
            if patchH > 8 {
                let leftRect = CGRect(x: s + 10, y: patchTop, width: (W - 2 * s - 30) / 2, height: patchH)
                var x = leftRect.minX
                var on = true
                while x < leftRect.maxX {
                    (on ? black : white).setFill()
                    ctx.fill(CGRect(x: x, y: leftRect.minY, width: 1, height: leftRect.height))
                    x += 1
                    on.toggle()
                }
                let rightRect = CGRect(x: leftRect.maxX + 10, y: patchTop, width: leftRect.width, height: patchH)
                var y = rightRect.minY
                on = true
                while y < rightRect.maxY {
                    (on ? red : white).setFill()
                    ctx.fill(CGRect(x: rightRect.minX, y: y, width: rightRect.width, height: 1))
                    y += 1
                    on.toggle()
                }
            }
        }
        guard let cg = image.cgImage else {
            return [UInt8](repeating: UInt8(Ink.white.rawValue), count: width * height)
        }
        let rgba = RenderEngine.rgbaBytes(cg, width: width, height: height)
        return Quantizer.nearestPure(rgba: rgba, width: width, height: height)
    }

    /// Corner where the black square appeared on the case.
    enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }

        var title: String {
            switch self {
            case .topLeft: return "Top left"
            case .topRight: return "Top right"
            case .bottomLeft: return "Bottom left"
            case .bottomRight: return "Bottom right"
            }
        }

        /// Flags (rotate180, mirror) that the observed corner implies. These
        /// transforms form a Klein four-group, so applying the same flags
        /// again (XOR) undoes the error.
        var correction: (rotate180: Bool, mirror: Bool) {
            switch self {
            case .topLeft: return (false, false)
            case .topRight: return (false, true)
            case .bottomRight: return (true, false)
            case .bottomLeft: return (true, true)
            }
        }
    }
}
