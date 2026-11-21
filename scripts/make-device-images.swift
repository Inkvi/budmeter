// Turns design/devices/<name>.png (transparent product images) into image sets in
// App/Assets.xcassets/Devices, trimmed to the product and centered on a square canvas.
// Run from the repo root: swift scripts/make-device-images.swift
import AppKit

let source = URL(fileURLWithPath: "design/devices")
let target = URL(fileURLWithPath: "App/Assets.xcassets/Devices")
try? FileManager.default.removeItem(at: target)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
try #"{"info":{"version":1,"author":"xcode"},"properties":{"provides-namespace":false}}"#
    .write(to: target.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

/// Bounding box of pixels that aren't (nearly) transparent.
func opaqueBounds(_ rep: NSBitmapImageRep) -> NSRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // colorAt uses a top-left origin; drawing uses bottom-left.
    return NSRect(x: minX, y: rep.pixelsHigh - maxY - 1, width: maxX - minX + 1, height: maxY - minY + 1)
}

func render(_ image: NSImage, crop: NSRect, px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let side = CGFloat(px) * 0.94
    let scale = side / max(crop.width, crop.height)
    let w = crop.width * scale, h = crop.height * scale
    image.draw(in: NSRect(x: (CGFloat(px) - w) / 2, y: (CGFloat(px) - h) / 2, width: w, height: h),
               from: crop, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    where file.pathExtension == "png" {
    let name = file.deletingPathExtension().lastPathComponent
    let rep = NSBitmapImageRep(data: try Data(contentsOf: file))!
    let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    image.addRepresentation(rep)
    let crop = opaqueBounds(rep)
    let set = target.appendingPathComponent("device-\(name).imageset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try render(image, crop: crop, px: 128).write(to: set.appendingPathComponent("\(name).png"))
    try render(image, crop: crop, px: 256).write(to: set.appendingPathComponent("\(name)@2x.png"))
    let contents = #"{"images":[{"idiom":"universal","filename":"\#(name).png","scale":"1x"},{"idiom":"universal","filename":"\#(name)@2x.png","scale":"2x"}],"info":{"version":1,"author":"xcode"}}"#
    try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("device-\(name)")
}
