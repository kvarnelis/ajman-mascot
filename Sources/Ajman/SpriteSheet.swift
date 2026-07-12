import AppKit
import ImageIO

enum SpriteSheetError: LocalizedError {
    case missing
    case unreadable(URL)
    case wrongSize(width: Int, height: Int)
    case cropFailed(column: Int, row: Int)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "No spritesheet was found in ~/.codex/pets/ajman/ or the app bundle."
        case .unreadable(let url):
            return "The spritesheet could not be decoded: \(url.path)"
        case .wrongSize(let width, let height):
            return "The spritesheet is \(width)×\(height), but Ajman requires 1536×1872."
        case .cropFailed(let column, let row):
            return "Could not slice spritesheet cell column \(column), row \(row)."
        }
    }
}

struct SpriteSheet {
    static let columns = 8
    static let rows = 9
    static let cellWidth = 192
    static let cellHeight = 208

    private let cells: [[CGImage]]

    static func load() throws -> SpriteSheet {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets/ajman/spritesheet.webp")
        let bundleURL = Bundle.main.url(forResource: "spritesheet", withExtension: "webp")
        let url: URL
        if FileManager.default.fileExists(atPath: homeURL.path) {
            url = homeURL
        } else if let bundleURL {
            url = bundleURL
        } else {
            throw SpriteSheetError.missing
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SpriteSheetError.unreadable(url)
        }
        guard image.width == columns * cellWidth, image.height == rows * cellHeight else {
            throw SpriteSheetError.wrongSize(width: image.width, height: image.height)
        }

        var cells: [[CGImage]] = []
        for row in 0..<rows {
            var rowImages: [CGImage] = []
            for column in 0..<columns {
                let rect = CGRect(
                    x: column * cellWidth,
                    y: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                guard let frame = image.cropping(to: rect) else {
                    throw SpriteSheetError.cropFailed(column: column, row: row)
                }
                rowImages.append(frame)
            }
            cells.append(rowImages)
        }
        return SpriteSheet(cells: cells)
    }

    func frames(for animation: AnimationState) -> [CGImage] {
        Array(cells[animation.row].prefix(animation.durations.count))
    }
}
