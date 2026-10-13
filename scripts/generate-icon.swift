import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: generate-icon OUTPUT_DIR [SOURCE_PNG]\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sourceURL = URL(fileURLWithPath: arguments.count > 2 ? arguments[2] : "branding/mochai-mascot.png")
guard let source = NSImage(contentsOf: sourceURL),
      let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("could not read \(sourceURL.path)\n", stderr)
    exit(1)
}

let cropped = cropToContent(cgImage)
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    guard let icon = renderIcon(cropped, size: size),
          let png = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:]) else {
        fputs("failed \(size)\n", stderr)
        exit(1)
    }
    try png.write(to: output.appendingPathComponent("icon_\(size).png"))
}
print("wrote icons")

func cropToContent(_ image: CGImage) -> CGImage {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return image
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0
    for y in 0..<height {
        for x in 0..<width {
            let alpha = bytes[(y * width + x) * 4 + 3]
            if alpha > 8 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return image }
    let pad = 28
    // CGContext is bottom-left; CGImage.cropping uses top-left.
    let top = height - 1 - maxY
    let bottom = height - 1 - minY
    let x0 = max(0, minX - pad)
    let y0 = max(0, top - pad)
    let x1 = min(width - 1, maxX + pad)
    let y1 = min(height - 1, bottom + pad)
    let rect = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    return image.cropping(to: rect) ?? image
}

func renderIcon(_ artwork: CGImage, size: Int) -> CGImage? {
    guard let canvas = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    canvas.setFillColor(CGColor(red: 247.0 / 255, green: 236.0 / 255, blue: 223.0 / 255, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let margin = CGFloat(size) * 0.045
    let target = CGFloat(size) - margin * 2
    let scale = min(target / CGFloat(artwork.width), target / CGFloat(artwork.height))
    let width = CGFloat(artwork.width) * scale
    let height = CGFloat(artwork.height) * scale
    canvas.interpolationQuality = .high
    canvas.draw(artwork, in: CGRect(
        x: (CGFloat(size) - width) / 2,
        y: (CGFloat(size) - height) / 2,
        width: width,
        height: height
    ))
    return canvas.makeImage()
}
