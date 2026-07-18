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
    struct ContentFitReference: Decodable {
        let width: Double
        let height: Double
    }

    let id: String?
    let displayName: String?
    let spriteVersionNumber: Int?
    let spritesheetPath: String?
    let contentFitReference: ContentFitReference?
}

struct SpriteSheet {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208
    static let contentAlphaThreshold: UInt8 = 10
    static let contentMargin = 4
    private static let topSafety: CGFloat = 2

    let animationTable: AnimationTable
    let sourceURL: URL
    private let cells: [[CGImage]]

    static func load() throws -> SpriteSheet {
        try PetCatalog().loadSelected().sheet
    }

    static func load(directory: URL) throws -> SpriteSheet {
        let manifestURL = directory.appendingPathComponent("pet.json")
        let sheetURL = directory.appendingPathComponent("spritesheet.webp")
        guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
            throw SpriteSheetError.missingPackage(directory)
        }
        return try load(manifestURL: manifestURL, defaultSheetURL: sheetURL)
    }

    private static func load(manifestURL: URL, defaultSheetURL: URL) throws -> SpriteSheet {
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
        let sheetURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent(manifest.spritesheetPath ?? defaultSheetURL.lastPathComponent)

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
        let fitReference = manifest.contentFitReference.map {
            CGSize(width: $0.width, height: $0.height)
        }
        let manifestID = manifest.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let petID = (manifestID?.isEmpty == false ? manifestID : nil)
            ?? manifestURL.deletingLastPathComponent().lastPathComponent
        if petID.caseInsensitiveCompare("winnie") == .orderedSame {
            cells = normalized(
                cells: cells,
                table: table,
                states: [.failed],
                minimumTargetBox: fitReference
            )
        }
        return SpriteSheet(animationTable: table, sourceURL: sheetURL, cells: cells)
    }

    func frames(for definition: AnimationDefinition) -> [CGImage] {
        Array(cells[definition.row].prefix(definition.frameCount))
    }

    func contentBounds(for definition: AnimationDefinition) -> [CGRect?] {
        frames(for: definition).map(Self.contentBounds)
    }

    private struct FrameLocation: Hashable {
        let row: Int
        let column: Int
    }

    private struct Bitmap {
        let data: [UInt8]
        let width: Int
        let height: Int
    }

    private static func normalized(
        cells: [[CGImage]],
        table: AnimationTable,
        states: Set<AnimationState>? = nil,
        minimumTargetBox: CGSize? = nil
    ) -> [[CGImage]] {
        var result = cells
        let used = table.definitions.flatMap { definition in
            (0..<definition.frameCount).map { FrameLocation(row: definition.row, column: $0) }
        }
        let selected = table.definitions
            .filter { states?.contains($0.state) ?? true }
            .flatMap { definition in
                (0..<definition.frameCount).map { FrameLocation(row: definition.row, column: $0) }
            }
        let measured = Dictionary(uniqueKeysWithValues: used.compactMap { location -> (FrameLocation, CGRect)? in
            guard let bitmap = rgbaBitmap(from: cells[location.row][location.column]),
                  let bounds = contentBounds(in: bitmap) else { return nil }
            return (location, bounds)
        })
        let idleBounds = table.definition(for: .idle).map { definition in
            (0..<definition.frameCount).compactMap { measured[FrameLocation(row: definition.row, column: $0)] }
        } ?? []
        let targetCandidates = idleBounds.isEmpty ? Array(measured.values) : idleBounds
        guard var targetBox = targetBox(for: targetCandidates) else { return result }
        if let minimumTargetBox {
            targetBox = CGSize(
                width: min(
                    max(targetBox.width, minimumTargetBox.width),
                    CGFloat(cellWidth) - 2 * CGFloat(contentMargin)
                ),
                height: min(
                    max(targetBox.height, minimumTargetBox.height),
                    CGFloat(cellHeight) - CGFloat(contentMargin) - topSafety
                )
            )
        }

        for location in selected {
            guard let bounds = measured[location],
                  let normalized = normalize(
                    cells[location.row][location.column],
                    contentBounds: bounds,
                    targetBox: targetBox
                  ) else { continue }
            result[location.row][location.column] = normalized
        }
        return result
    }

    private static func normalize(_ frame: CGImage, contentBounds: CGRect, targetBox: CGSize) -> CGImage? {
        guard let scale = normalizationScale(contentSize: contentBounds.size, targetBox: targetBox),
              let context = rgbaContext(width: cellWidth, height: cellHeight) else { return nil }

        context.interpolationQuality = .high
        let scaledContentWidth = contentBounds.width * scale
        let contentLeft = (CGFloat(cellWidth) - scaledContentWidth) / 2
        let drawRect = CGRect(
            x: contentLeft - contentBounds.minX * scale,
            y: CGFloat(contentMargin) - contentBounds.minY * scale,
            width: CGFloat(cellWidth) * scale,
            height: CGFloat(cellHeight) * scale
        )
        context.draw(frame, in: drawRect)
        guard let rendered = context.makeImage(),
              let renderedBounds = Self.contentBounds(rendered) else { return context.makeImage() }
        // CGImage scanlines and CGContext user-space Y run in opposite directions.
        let verticalCorrection = renderedBounds.minY - CGFloat(contentMargin)
        guard abs(verticalCorrection) >= 0.5,
              let corrected = rgbaContext(width: cellWidth, height: cellHeight) else { return rendered }
        corrected.draw(
            rendered,
            in: CGRect(x: 0, y: verticalCorrection, width: CGFloat(cellWidth), height: CGFloat(cellHeight))
        )
        return corrected.makeImage() ?? rendered
    }

    private static func targetBox(for idleBounds: [CGRect]) -> CGSize? {
        guard let widest = idleBounds.map(\.width).max(),
              let tallest = idleBounds.map(\.height).max(),
              widest > 0, tallest > 0 else { return nil }
        return CGSize(
            width: min(widest, CGFloat(cellWidth - 2 * contentMargin)),
            height: min(tallest, CGFloat(cellHeight - contentMargin) - topSafety)
        )
    }

    private static func normalizationScale(contentSize: CGSize, targetBox: CGSize) -> CGFloat? {
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        let usableWidth = CGFloat(cellWidth - 2 * contentMargin)
        let usableHeight = CGFloat(cellHeight - contentMargin) - topSafety
        let scale = min(
            targetBox.width / contentSize.width,
            targetBox.height / contentSize.height,
            usableWidth / contentSize.width,
            usableHeight / contentSize.height
        )
        return scale.isFinite && scale > 0 ? scale : nil
    }

    static func contentBounds(_ image: CGImage) -> CGRect? {
        guard let bitmap = rgbaBitmap(from: image) else { return nil }
        return contentBounds(in: bitmap)
    }

    private static func rgbaBitmap(from image: CGImage) -> Bitmap? {
        let width = image.width
        let height = image.height
        guard let context = rgbaContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pointer = context.data else { return nil }
        let data = Array(UnsafeBufferPointer(
            start: pointer.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4
        ))
        return Bitmap(data: data, width: width, height: height)
    }

    private static func rgbaContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func contentBounds(in bitmap: Bitmap) -> CGRect? {
        var minX = bitmap.width
        var minY = bitmap.height
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width
                where bitmap.data[(y * bitmap.width + x) * 4 + 3] > contentAlphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

}
