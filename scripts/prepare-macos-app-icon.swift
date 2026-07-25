#!/usr/bin/env swift

import AppKit
import Foundation

private struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    static func average(_ colors: [RGB]) -> RGB {
        let count = CGFloat(colors.count)
        return RGB(
            red: colors.reduce(0) { $0 + $1.red } / count,
            green: colors.reduce(0) { $0 + $1.green } / count,
            blue: colors.reduce(0) { $0 + $1.blue } / count
        )
    }
}

private func rgb(_ color: NSColor?) -> RGB? {
    guard let converted = color?.usingColorSpace(.deviceRGB) else {
        return nil
    }
    return RGB(
        red: converted.redComponent,
        green: converted.greenComponent,
        blue: converted.blueComponent
    )
}

private func prepareFullBleedArtwork(at url: URL) throws {
    let sourceData = try Data(contentsOf: url)
    guard let bitmap = NSBitmapImageRep(data: sourceData) else {
        throw NSError(
            domain: "KiwiAppIcon",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "无法读取 \(url.path)"]
        )
    }

    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    let inset = max(1, min(width, height) / 100)
    let cornerSamples = [
        rgb(bitmap.colorAt(x: 0, y: 0)),
        rgb(bitmap.colorAt(x: width - 1, y: 0)),
        rgb(bitmap.colorAt(x: 0, y: height - 1)),
        rgb(bitmap.colorAt(x: width - 1, y: height - 1))
    ].compactMap { $0 }
    let greenSamples = [
        rgb(bitmap.colorAt(x: width / 2, y: inset)),
        rgb(bitmap.colorAt(x: width / 2, y: height - 1 - inset)),
        rgb(bitmap.colorAt(x: inset, y: height / 2)),
        rgb(bitmap.colorAt(x: width - 1 - inset, y: height / 2))
    ].compactMap { $0 }
    guard cornerSamples.count == 4, greenSamples.count == 4 else {
        throw NSError(
            domain: "KiwiAppIcon",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "无法采样 \(url.path) 的颜色"]
        )
    }

    let background = RGB.average(cornerSamples)
    let green = RGB.average(greenSamples)
    let vector = RGB(
        red: green.red - background.red,
        green: green.green - background.green,
        blue: green.blue - background.blue
    )
    let redLength = vector.red * vector.red
    let greenLength = vector.green * vector.green
    let blueLength = vector.blue * vector.blue
    let vectorLengthSquared = redLength + greenLength + blueLength
    guard vectorLengthSquared > 0.01 else {
        print("已是全尺寸图标，跳过 \(url.lastPathComponent)")
        return
    }

    guard let replacement = bitmap.colorAt(x: width / 2, y: inset) else {
        throw NSError(
            domain: "KiwiAppIcon",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "无法读取 \(url.path) 的背景色"]
        )
    }
    let cornerSpan = max(2, Int(ceil(CGFloat(min(width, height)) * 0.22)))
    let residualLimit: CGFloat = 0.1
    var changed = 0

    for y in 0..<height {
        let nearVerticalEdge = y < cornerSpan || y >= height - cornerSpan
        guard nearVerticalEdge else { continue }
        for x in 0..<width {
            let nearHorizontalEdge = x < cornerSpan || x >= width - cornerSpan
            guard nearHorizontalEdge, let pixel = rgb(bitmap.colorAt(x: x, y: y)) else {
                continue
            }

            let delta = RGB(
                red: pixel.red - background.red,
                green: pixel.green - background.green,
                blue: pixel.blue - background.blue
            )
            let redProjection = delta.red * vector.red
            let greenProjection = delta.green * vector.green
            let blueProjection = delta.blue * vector.blue
            let projection = (
                redProjection + greenProjection + blueProjection
            ) / vectorLengthSquared
            guard projection >= -0.15, projection <= 1.15 else { continue }

            let residual = hypot(
                hypot(
                    delta.red - projection * vector.red,
                    delta.green - projection * vector.green
                ),
                delta.blue - projection * vector.blue
            )
            guard residual <= residualLimit else { continue }
            bitmap.setColor(replacement, atX: x, y: y)
            changed += 1
        }
    }

    guard let png = bitmap.representation(
        using: NSBitmapImageRep.FileType.png,
        properties: [:]
    ) else {
        throw NSError(
            domain: "KiwiAppIcon",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "无法编码 \(url.path)"]
        )
    }
    try png.write(to: url, options: Data.WritingOptions.atomic)
    print("已处理 \(url.lastPathComponent)：\(changed) 个蒙版像素")
}

private let scriptURL = URL(fileURLWithPath: #filePath)
private let projectURL = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let appIconDirectory = projectURL
    .appendingPathComponent("Assets/AppIcon.xcassets/AppIcon.appiconset")
private let previewIcon = projectURL
    .appendingPathComponent("Assets/AppIcon/KiwiIcon.png")
private let fileManager = FileManager.default

let appIconPNGs = try fileManager
    .contentsOfDirectory(
        at: appIconDirectory,
        includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for iconURL in appIconPNGs + [previewIcon] {
    try prepareFullBleedArtwork(at: iconURL)
}

private func bigEndianData(_ value: Int) -> Data {
    var encoded = UInt32(value).bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}

let iconEntries = [
    ("ic04", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic05", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

var iconBody = Data()
for (type, filename) in iconEntries {
    let png = try Data(
        contentsOf: appIconDirectory.appendingPathComponent(filename)
    )
    iconBody.append(Data(type.utf8))
    iconBody.append(bigEndianData(png.count + 8))
    iconBody.append(png)
}

var iconContainer = Data("icns".utf8)
iconContainer.append(bigEndianData(iconBody.count + 8))
iconContainer.append(iconBody)
let icnsURL = projectURL.appendingPathComponent(
    "Assets/AppIcon/AppIcon.icns"
)
try iconContainer.write(to: icnsURL, options: Data.WritingOptions.atomic)
print("已重新生成 Assets/AppIcon/AppIcon.icns")
