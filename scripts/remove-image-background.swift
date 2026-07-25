import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs(
        "Usage: swift remove-image-background.swift <input.png> <output.png>\n",
        stderr
    )
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let sourceImage = NSImage(contentsOf: inputURL),
      let sourceRepresentation = sourceImage.representations.first else {
    fputs("Could not load \(inputURL.path)\n", stderr)
    exit(1)
}

let width = sourceRepresentation.pixelsWide
let height = sourceRepresentation.pixelsHigh
guard width > 0, height > 0,
      let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: width,
          pixelsHigh: height,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bitmapFormat: [],
          bytesPerRow: 0,
          bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create output bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
sourceImage.draw(
    in: NSRect(x: 0, y: 0, width: width, height: height),
    from: .zero,
    operation: .copy,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

let pixelCount = width * height
var isOutsideBackground = [Bool](repeating: false, count: pixelCount)
var queue: [Int] = []
queue.reserveCapacity(pixelCount / 2)

func index(x: Int, y: Int) -> Int {
    y * width + x
}

func isNearWhite(x: Int, y: Int) -> Bool {
    guard let color = bitmap.colorAt(x: x, y: y)?
        .usingColorSpace(.deviceRGB) else {
        return false
    }
    return color.alphaComponent > 0.01
        && color.redComponent > 0.975
        && color.greenComponent > 0.975
        && color.blueComponent > 0.975
}

func enqueueIfBackground(x: Int, y: Int) {
    let pixelIndex = index(x: x, y: y)
    guard !isOutsideBackground[pixelIndex],
          isNearWhite(x: x, y: y) else {
        return
    }
    isOutsideBackground[pixelIndex] = true
    queue.append(pixelIndex)
}

for x in 0..<width {
    enqueueIfBackground(x: x, y: 0)
    enqueueIfBackground(x: x, y: height - 1)
}
for y in 0..<height {
    enqueueIfBackground(x: 0, y: y)
    enqueueIfBackground(x: width - 1, y: y)
}

var queueIndex = 0
while queueIndex < queue.count {
    let pixelIndex = queue[queueIndex]
    queueIndex += 1
    let x = pixelIndex % width
    let y = pixelIndex / width

    if x > 0 {
        enqueueIfBackground(x: x - 1, y: y)
    }
    if x + 1 < width {
        enqueueIfBackground(x: x + 1, y: y)
    }
    if y > 0 {
        enqueueIfBackground(x: x, y: y - 1)
    }
    if y + 1 < height {
        enqueueIfBackground(x: x, y: y + 1)
    }
}

let clear = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
for pixelIndex in queue {
    bitmap.setColor(
        clear,
        atX: pixelIndex % width,
        y: pixelIndex / width
    )
}

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode PNG\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try pngData.write(to: outputURL, options: .atomic)
