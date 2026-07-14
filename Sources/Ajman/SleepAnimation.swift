import AppKit
import ImageIO

enum SleepAnimationError: LocalizedError {
    case unreadable(URL)
    case wrongSize(URL, width: Int, height: Int)
    case cropFailed(URL, column: Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            "The sleep animation could not be decoded: \(url.path)"
        case let .wrongSize(url, width, height):
            "The sleep animation at \(url.path) is \(width)×\(height); it must be a horizontal strip of 192×208 cells."
        case let .cropFailed(url, column):
            "Could not slice sleep frame \(column) from \(url.path)."
        }
    }
}

struct SleepAnimation {
    let frames: [CGImage]
    let poseWeights: [Double]
    let sourceURL: URL

    var frameCount: Int { frames.count }

    static func load(from url: URL, poseWeights: [Double]? = nil) throws -> SleepAnimation {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SleepAnimationError.unreadable(url)
        }
        guard image.height == SpriteSheet.cellHeight,
              image.width >= SpriteSheet.cellWidth,
              image.width % SpriteSheet.cellWidth == 0 else {
            throw SleepAnimationError.wrongSize(url, width: image.width, height: image.height)
        }

        let frameCount = image.width / SpriteSheet.cellWidth
        let frames = try (0..<frameCount).map { column in
            let rect = CGRect(
                x: column * SpriteSheet.cellWidth,
                y: 0,
                width: SpriteSheet.cellWidth,
                height: SpriteSheet.cellHeight
            )
            guard let frame = image.cropping(to: rect) else {
                throw SleepAnimationError.cropFailed(url, column: column)
            }
            return frame
        }
        let resolvedWeights = poseWeights.flatMap { $0.count == frameCount ? $0 : nil }
            ?? Array(repeating: 1, count: frameCount)
        return SleepAnimation(frames: frames, poseWeights: resolvedWeights, sourceURL: url)
    }
}
