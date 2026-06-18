import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum ScreenCaptureService {
    static func captureMainDisplayPNG() async throws -> Data {
        let cgImage = try await captureMainDisplayCGImage()
        return try pngData(from: cgImage)
    }

    static func captureMainDisplayJPEG(maxDimension: Int = 1280, compression: Double = 0.72) async throws -> Data {
        let cgImage = try await captureMainDisplayCGImage()
        let resized = resizeIfNeeded(cgImage, maxDimension: maxDimension) ?? cgImage
        return try jpegData(from: resized, compression: compression)
    }

    private static func captureMainDisplayCGImage() async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw CaptureError.permissionDenied
        }

        if #available(macOS 14.0, *), let cgImage = try? await captureWithScreenCaptureKit() {
            return cgImage
        }

        guard let cgImage = CGDisplayCreateImage(CGMainDisplayID()) else {
            throw CaptureError.failedAfterPermission
        }

        return cgImage
    }

    private static func pngData(from cgImage: CGImage) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }
        return data
    }

    private static func jpegData(from cgImage: CGImage, compression: Double) throws -> Data {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: compression]) else {
            throw CaptureError.jpegEncodingFailed
        }
        return data
    }

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainDisplayID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func resizeIfNeeded(_ cgImage: CGImage, maxDimension: Int) -> CGImage? {
        guard maxDimension > 0 else { return cgImage }

        let width = cgImage.width
        let height = cgImage.height
        let longestEdge = max(width, height)
        guard longestEdge > maxDimension else { return cgImage }

        let scale = Double(maxDimension) / Double(longestEdge)
        let targetWidth = max(1, Int(Double(width) * scale))
        let targetHeight = max(1, Int(Double(height) * scale))

        guard
            let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case failedAfterPermission
    case noDisplay
    case pngEncodingFailed
    case jpegEncodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen capture permission is not active for this running app. Enable April AI in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen the app."
        case .failedAfterPermission:
            "Screen capture returned no image even though permission appears enabled. Quit and reopen April AI so macOS reloads the Screen Recording permission."
        case .noDisplay:
            "Screen capture found no visible display to capture."
        case .pngEncodingFailed:
            "Screen capture worked, but the app could not encode the screenshot as PNG."
        case .jpegEncodingFailed:
            "Screen capture worked, but the app could not encode the live frame as JPEG."
        }
    }
}
