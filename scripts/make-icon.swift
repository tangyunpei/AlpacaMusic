import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Source artwork is a build-time asset; only the generated ICNS enters the app.
// An SVG source is drawn as vectors at every size; a PNG must be a square of
// at least 1024 pixels.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: make-icon.swift OUTPUT_DIRECTORY SOURCE_SVG_OR_PNG")
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2])

enum Artwork {
    case vector(NSImage)
    case bitmap(CGImage)

    func draw(in context: CGContext, rect: CGRect) {
        switch self {
        case .bitmap(let image):
            context.draw(image, in: rect)
        case .vector(let image):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

let artwork: Artwork
if sourceURL.pathExtension.lowercased() == "svg" {
    guard let image = NSImage(contentsOf: sourceURL), image.size.width > 0,
          abs(image.size.width - image.size.height) < 0.5 else {
        fatalError("App icon SVG must be square and readable: \(sourceURL.path)")
    }
    artwork = .vector(image)
} else {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == image.height, image.width >= 1024 else {
        fatalError("App icon artwork must be a square image of at least 1024 pixels: \(sourceURL.path)")
    }
    artwork = .bitmap(image)
}
guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("Unable to create sRGB icon color space")
}
let folder = root.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (size, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),(128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),(512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Unable to render icon") }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let bounds = CGRect(x: 74, y: 74, width: 876, height: 876)
    let shape = CGPath(roundedRect: bounds, cornerWidth: 204, cornerHeight: 204, transform: nil)
    ctx.addPath(shape); ctx.clip()
    ctx.interpolationQuality = .high
    artwork.draw(in: ctx, rect: bounds)
    guard let image = ctx.makeImage(), let destination = CGImageDestinationCreateWithURL(folder.appending(path: name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Unable to save icon") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Unable to finalize icon") }
}
