import AppKit
import ImageIO

enum SpriteSheetError: LocalizedError {
    case missingPackage(URL)
    case missingBundlePackage
    case invalidManifest(URL, Error)
    case unknownVersion(Int)
    case unreadable(URL)
    case wrongSize(version: Int, width: Int, height: Int, expectedWidth: Int, expectedHeight: Int)
    case cropFailed(column: Int, row: Int)
    case invalidAnimationTable(version: Int, expectedFrames: Int, availableFrames: Int)

    var errorDescription: String? {
        switch self {
        case .missingPackage(let url):
            "Pet package is missing pet.json or spritesheet.webp at \(url.path)."
        case .missingBundlePackage:
            "The bundled pet package is missing pet.json or spritesheet.webp."
        case .invalidManifest(let url, let error):
            "The pet manifest could not be decoded at \(url.path): \(error.localizedDescription)"
        case .unknownVersion(let version):
            "Unsupported spriteVersionNumber \(version); Ajman supports versions 1 and 2."
        case .unreadable(let url):
            "The spritesheet could not be decoded: \(url.path)"
        case let .wrongSize(version, width, height, expectedWidth, expectedHeight):
            "The v\(version) spritesheet is \(width)×\(height), but must be \(expectedWidth)×\(expectedHeight)."
        case .cropFailed(let column, let row):
            "Could not slice spritesheet cell column \(column), row \(row)."
        case let .invalidAnimationTable(version, expectedFrames, availableFrames):
            "The v\(version) animation table requests \(expectedFrames) frames, but only \(availableFrames) are available."
        }
    }
}

private struct PetManifest: Decodable {
    let spriteVersionNumber: Int?
    let spritesheetPath: String?
}

struct SpriteSheet {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208

    let animationTable: AnimationTable
    let sourceURL: URL
    private let cells: [[CGImage]]

    static func load() throws -> SpriteSheet {
        let liveDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets/ajman", isDirectory: true)
        do {
            return try load(directory: liveDirectory, isBundle: false)
        } catch {
            FileHandle.standardError.write(Data("Ajman: live pet load failed: \(error.localizedDescription)\n".utf8))
        }

        do {
            return try loadBundlePackage()
        } catch {
            FileHandle.standardError.write(Data("Ajman: bundled pet load failed: \(error.localizedDescription)\n".utf8))
            throw error
        }
    }

    private static func loadBundlePackage() throws -> SpriteSheet {
        guard let manifestURL = Bundle.main.url(forResource: "pet", withExtension: "json"),
              let sheetURL = Bundle.main.url(forResource: "spritesheet", withExtension: "webp") else {
            throw SpriteSheetError.missingBundlePackage
        }
        return try load(manifestURL: manifestURL, defaultSheetURL: sheetURL, isBundle: true)
    }

    private static func load(directory: URL, isBundle: Bool) throws -> SpriteSheet {
        let manifestURL = directory.appendingPathComponent("pet.json")
        let sheetURL = directory.appendingPathComponent("spritesheet.webp")
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: sheetURL.path) else {
            throw SpriteSheetError.missingPackage(directory)
        }
        return try load(manifestURL: manifestURL, defaultSheetURL: sheetURL, isBundle: isBundle)
    }

    private static func load(manifestURL: URL, defaultSheetURL: URL, isBundle: Bool) throws -> SpriteSheet {
        let manifest: PetManifest
        do {
            manifest = try JSONDecoder().decode(PetManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw SpriteSheetError.invalidManifest(manifestURL, error)
        }

        let version = manifest.spriteVersionNumber ?? 1
        let table = try AnimationTable.forVersion(version)
        let rows = version == 2 ? 11 : 9
        let expectedWidth = columns * cellWidth
        let expectedHeight = rows * cellHeight
        let sheetURL: URL
        if isBundle {
            // Bundle resources are flattened by build-app.sh; honor only the file name.
            let name = URL(fileURLWithPath: manifest.spritesheetPath ?? defaultSheetURL.lastPathComponent).lastPathComponent
            sheetURL = Bundle.main.url(
                forResource: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
                withExtension: URL(fileURLWithPath: name).pathExtension
            ) ?? defaultSheetURL
        } else {
            sheetURL = manifestURL.deletingLastPathComponent()
                .appendingPathComponent(manifest.spritesheetPath ?? defaultSheetURL.lastPathComponent)
        }

        guard let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SpriteSheetError.unreadable(sheetURL)
        }
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw SpriteSheetError.wrongSize(
                version: version,
                width: image.width,
                height: image.height,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        }

        var cells: [[CGImage]] = []
        for row in 0..<rows {
            var rowImages: [CGImage] = []
            for column in 0..<columns {
                let rect = CGRect(x: column * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)
                guard let frame = image.cropping(to: rect) else {
                    throw SpriteSheetError.cropFailed(column: column, row: row)
                }
                rowImages.append(frame)
            }
            cells.append(rowImages)
        }
        let availableFrames = table.definitions.reduce(0) { count, definition in
            guard cells.indices.contains(definition.row) else { return count }
            return count + min(cells[definition.row].count, definition.frameCount)
        }
        guard availableFrames == table.usedFrameCount else {
            throw SpriteSheetError.invalidAnimationTable(
                version: version,
                expectedFrames: table.usedFrameCount,
                availableFrames: availableFrames
            )
        }
        return SpriteSheet(animationTable: table, sourceURL: sheetURL, cells: cells)
    }

    func frames(for definition: AnimationDefinition) -> [CGImage] {
        Array(cells[definition.row].prefix(definition.frameCount))
    }
}
