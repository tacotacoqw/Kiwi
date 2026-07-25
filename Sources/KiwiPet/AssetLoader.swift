import AppKit

enum AssetLoader {
    static func frame(named name: String) -> NSImage? {
        image(named: name, resourceDirectory: "Frames")
    }

    static func icon(named name: String) -> NSImage? {
        guard let image = image(
            named: name,
            resourceDirectory: "Icons"
        ) else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    static func sound(named name: String) -> NSSound? {
        resourceCandidates(
            named: name,
            resourceDirectory: "Sounds"
        )
        .lazy
        .compactMap {
            NSSound(contentsOf: $0, byReference: true)
        }
        .first
    }

    private static func image(
        named name: String,
        resourceDirectory: String
    ) -> NSImage? {
        resourceCandidates(
            named: name,
            resourceDirectory: resourceDirectory
        )
        .lazy
        .compactMap(NSImage.init(contentsOf:))
        .first
    }

    private static func resourceCandidates(
        named name: String,
        resourceDirectory: String
    ) -> [URL] {
        [
            Bundle.main.resourceURL?
                .appendingPathComponent(
                    resourceDirectory,
                    isDirectory: true
                )
                .appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    "Assets/\(resourceDirectory)",
                    isDirectory: true
                )
                .appendingPathComponent(name)
        ].compactMap { $0 }
    }
}
