#!/usr/bin/env swift
import CoreGraphics
import Foundation

struct Geometry {
    let displayID: UInt32
    let logicalBounds: CGRect
    let capturePixelWidth: Double
    let capturePixelHeight: Double
    let sentImageWidth: Double
    let sentImageHeight: Double
    let backingScaleFactor: Double
}

func screenGeometryMetadata(_ geometry: Geometry, mouse: CGPoint) -> [String: Any] {
    [
        "display_id": geometry.displayID,
        "capture_pixels": ["width": geometry.capturePixelWidth, "height": geometry.capturePixelHeight],
        "sent_image_pixels": ["width": geometry.sentImageWidth, "height": geometry.sentImageHeight],
        "logical_bounds": [
            "x": geometry.logicalBounds.origin.x,
            "y": geometry.logicalBounds.origin.y,
            "width": geometry.logicalBounds.width,
            "height": geometry.logicalBounds.height
        ],
        "backing_scale_factor": geometry.backingScaleFactor,
        "current_mouse": ["x": mouse.x, "y": mouse.y]
    ]
}

func pointFromImagePixels(x: Double, y: Double, geometry: Geometry) -> CGPoint {
    CGPoint(
        x: geometry.logicalBounds.minX + x * geometry.logicalBounds.width / geometry.sentImageWidth,
        y: geometry.logicalBounds.minY + y * geometry.logicalBounds.height / geometry.sentImageHeight
    )
}

func imagePointIsInBounds(x: Double, y: Double, geometry: Geometry) -> Bool {
    (0...geometry.sentImageWidth).contains(x) && (0...geometry.sentImageHeight).contains(y)
}

func normalizedPointIsValid(x: Double, y: Double) -> Bool {
    (0...1).contains(x) && (0...1).contains(y)
}

func pointFromNormalized(x: Double, y: Double, geometry: Geometry) -> CGPoint {
    CGPoint(
        x: geometry.logicalBounds.minX + geometry.logicalBounds.width * x,
        y: geometry.logicalBounds.minY + geometry.logicalBounds.height * y
    )
}

func assertClose(_ actual: CGFloat, _ expected: CGFloat, _ label: String) {
    let delta = abs(actual - expected)
    guard delta < 0.001 else {
        fputs("FAIL \(label): expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

let retinaResized = Geometry(
    displayID: 1,
    logicalBounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    capturePixelWidth: 3456,
    capturePixelHeight: 2234,
    sentImageWidth: 1280,
    sentImageHeight: 827,
    backingScaleFactor: 2
)
let centerFromImage = pointFromImagePixels(x: 640, y: 413.5, geometry: retinaResized)
assertClose(centerFromImage.x, 864, "retina resized x")
assertClose(centerFromImage.y, 558.5, "retina resized y")

let normalizedCenter = pointFromNormalized(x: 0.5, y: 0.5, geometry: retinaResized)
assertClose(normalizedCenter.x, 864, "normalized x")
assertClose(normalizedCenter.y, 558.5, "normalized y")

let offsetDisplay = Geometry(
    displayID: 2,
    logicalBounds: CGRect(x: 100, y: 40, width: 1470, height: 956),
    capturePixelWidth: 2940,
    capturePixelHeight: 1912,
    sentImageWidth: 1280,
    sentImageHeight: 833,
    backingScaleFactor: 2
)
let offsetPoint = pointFromImagePixels(x: 0, y: 0, geometry: offsetDisplay)
assertClose(offsetPoint.x, 100, "offset origin x")
assertClose(offsetPoint.y, 40, "offset origin y")

let ambiguousRawCoordinate = Double("900") ?? 0
if ambiguousRawCoordinate <= 1 {
    fputs("FAIL ambiguous raw coordinate fixture is invalid\n", stderr)
    exit(1)
}
if normalizedPointIsValid(x: ambiguousRawCoordinate, y: 0.5) {
    fputs("FAIL raw pixel-looking x should not be accepted as normalized\n", stderr)
    exit(1)
}
if !imagePointIsInBounds(x: 1279, y: 826, geometry: retinaResized) {
    fputs("FAIL valid image point rejected\n", stderr)
    exit(1)
}
if imagePointIsInBounds(x: 1400, y: 826, geometry: retinaResized) {
    fputs("FAIL out-of-bounds image point accepted\n", stderr)
    exit(1)
}

let metadata = screenGeometryMetadata(retinaResized, mouse: CGPoint(x: 10, y: 20))
guard
    let sent = metadata["sent_image_pixels"] as? [String: Double],
    sent["width"] == 1280,
    metadata["backing_scale_factor"] as? Double == 2
else {
    fputs("FAIL screen geometry metadata missing expected values\n", stderr)
    exit(1)
}

print("PASS: coordinate mapping smoke checks passed.")
