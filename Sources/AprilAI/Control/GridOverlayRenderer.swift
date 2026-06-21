import AppKit
import Foundation

enum GridOverlayRenderer {
    static func renderPNG(basePNG: Data, columns: Int = 12, rows: Int = 8, minorDivisions: Int = 4) throws -> Data {
        guard
            let image = NSImage(data: basePNG),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            throw GridOverlayError.decodeFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw GridOverlayError.renderFailed
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer {
            NSGraphicsContext.restoreGraphicsState()
        }

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSImage(cgImage: cgImage, size: rect.size).draw(in: rect)

        drawGrid(width: width, height: height, columns: columns, rows: rows, minorDivisions: minorDivisions)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw GridOverlayError.renderFailed
        }
        return data
    }

    private static func drawGrid(width: Int, height: Int, columns: Int, rows: Int, minorDivisions: Int) {
        let cellWidth = CGFloat(width) / CGFloat(columns)
        let cellHeight = CGFloat(height) / CGFloat(rows)

        if minorDivisions > 1 {
            let minorPath = NSBezierPath()
            minorPath.lineWidth = max(0.5, CGFloat(max(width, height)) / 2600)
            for column in 0..<columns {
                for division in 1..<minorDivisions {
                    let x = (CGFloat(column) + CGFloat(division) / CGFloat(minorDivisions)) * cellWidth
                    minorPath.move(to: NSPoint(x: x, y: 0))
                    minorPath.line(to: NSPoint(x: x, y: CGFloat(height)))
                }
            }
            for row in 0..<rows {
                for division in 1..<minorDivisions {
                    let y = (CGFloat(row) + CGFloat(division) / CGFloat(minorDivisions)) * cellHeight
                    minorPath.move(to: NSPoint(x: 0, y: y))
                    minorPath.line(to: NSPoint(x: CGFloat(width), y: y))
                }
            }
            NSColor.white.withAlphaComponent(0.08).setStroke()
            minorPath.stroke()
        }

        let path = NSBezierPath()
        path.lineWidth = max(1, CGFloat(max(width, height)) / 1200)
        for column in 0...columns {
            let x = CGFloat(column) * cellWidth
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: CGFloat(height)))
        }

        for row in 0...rows {
            let y = CGFloat(row) * cellHeight
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: CGFloat(width), y: y))
        }

        NSColor.white.withAlphaComponent(0.22).setStroke()
        path.stroke()

        let fontSize = max(10, min(15, CGFloat(width) / 92))
        let axisAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize + 1, weight: .bold),
            .foregroundColor: NSColor.systemYellow.withAlphaComponent(0.82),
            .backgroundColor: NSColor.black.withAlphaComponent(0.28)
        ]

        for column in 0..<columns {
            let label = columnLabel(column)
            label.draw(
                at: NSPoint(x: CGFloat(column) * cellWidth + (cellWidth * 0.45), y: CGFloat(height) - fontSize - 8),
                withAttributes: axisAttributes
            )
        }

        for row in 0..<rows {
            let label = "\(row + 1)"
            label.draw(
                at: NSPoint(x: 8, y: CGFloat(height) - (CGFloat(row) * cellHeight) - (cellHeight * 0.55)),
                withAttributes: axisAttributes
            )
        }

        drawCellLabels(width: width, height: height, columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        drawPixelRulers(width: width, height: height)
    }

    private static func drawCellLabels(
        width: Int,
        height: Int,
        columns: Int,
        rows: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) {
        let fontSize = max(7, min(10, CGFloat(width) / 150))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.systemYellow.withAlphaComponent(0.36),
            .backgroundColor: NSColor.black.withAlphaComponent(0.10)
        ]

        for column in 0..<columns {
            for row in 0..<rows {
                let label = "\(columnLabel(column))\(row + 1)"
                let x = CGFloat(column) * cellWidth + 5
                let y = CGFloat(height) - (CGFloat(row + 1) * cellHeight) + 5
                label.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            }
        }
    }

    private static func drawPixelRulers(width: Int, height: Int) {
        let tickStep = max(40, Int(round(Double(width) / 16.0 / 20.0)) * 20)
        let fontSize = max(8, min(11, CGFloat(width) / 128))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.systemCyan.withAlphaComponent(0.72),
            .backgroundColor: NSColor.black.withAlphaComponent(0.22)
        ]

        let tickPath = NSBezierPath()
        tickPath.lineWidth = max(0.5, CGFloat(max(width, height)) / 2600)

        var x = 0
        while x <= width {
            let pointX = CGFloat(x)
            tickPath.move(to: NSPoint(x: pointX, y: CGFloat(height)))
            tickPath.line(to: NSPoint(x: pointX, y: CGFloat(height) - 8))
            if x > 0 && x < width {
                "\(x)".draw(at: NSPoint(x: pointX + 3, y: CGFloat(height) - fontSize - 24), withAttributes: attributes)
            }
            x += tickStep
        }

        var y = 0
        while y <= height {
            let pointY = CGFloat(height - y)
            tickPath.move(to: NSPoint(x: 0, y: pointY))
            tickPath.line(to: NSPoint(x: 8, y: pointY))
            if y > 0 && y < height {
                "\(y)".draw(at: NSPoint(x: 20, y: pointY - fontSize - 2), withAttributes: attributes)
            }
            y += tickStep
        }

        NSColor.systemCyan.withAlphaComponent(0.14).setStroke()
        tickPath.stroke()
    }

    private static func columnLabel(_ index: Int) -> String {
        var value = index
        var label = ""
        repeat {
            let scalar = UnicodeScalar(65 + (value % 26))!
            label.insert(Character(scalar), at: label.startIndex)
            value = (value / 26) - 1
        } while value >= 0
        return label
    }
}

enum GridOverlayError: LocalizedError {
    case decodeFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .decodeFailed:
            "Could not decode the screenshot before drawing the coordinate grid."
        case .renderFailed:
            "Could not render the screenshot coordinate grid."
        }
    }
}
