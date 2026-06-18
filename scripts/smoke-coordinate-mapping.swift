#!/usr/bin/env swift
import CoreGraphics
import Foundation

struct Geometry {
    let logicalBounds: CGRect
    let sentImageWidth: Double
    let sentImageHeight: Double
}

func pointFromImagePixels(x: Double, y: Double, geometry: Geometry) -> CGPoint {
    CGPoint(
        x: geometry.logicalBounds.minX + x * geometry.logicalBounds.width / geometry.sentImageWidth,
        y: geometry.logicalBounds.minY + y * geometry.logicalBounds.height / geometry.sentImageHeight
    )
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
    logicalBounds: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    sentImageWidth: 1280,
    sentImageHeight: 827
)
let centerFromImage = pointFromImagePixels(x: 640, y: 413.5, geometry: retinaResized)
assertClose(centerFromImage.x, 864, "retina resized x")
assertClose(centerFromImage.y, 558.5, "retina resized y")

let normalizedCenter = pointFromNormalized(x: 0.5, y: 0.5, geometry: retinaResized)
assertClose(normalizedCenter.x, 864, "normalized x")
assertClose(normalizedCenter.y, 558.5, "normalized y")

let offsetDisplay = Geometry(
    logicalBounds: CGRect(x: 100, y: 40, width: 1470, height: 956),
    sentImageWidth: 1280,
    sentImageHeight: 833
)
let offsetPoint = pointFromImagePixels(x: 0, y: 0, geometry: offsetDisplay)
assertClose(offsetPoint.x, 100, "offset origin x")
assertClose(offsetPoint.y, 40, "offset origin y")

let ambiguousRawCoordinate = Double("900") ?? 0
if ambiguousRawCoordinate <= 1 {
    fputs("FAIL ambiguous raw coordinate fixture is invalid\n", stderr)
    exit(1)
}

print("PASS: coordinate mapping smoke checks passed.")
