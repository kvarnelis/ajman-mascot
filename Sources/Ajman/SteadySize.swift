import CoreGraphics
import Foundation

enum SteadySize {
    static let defaultsKey = "AjmanSteadySize"
    static let margin: CGFloat = 4
    static let topSafety: CGFloat = 2

    static func targetBox(idleBounds: [CGRect], cellWidth: Int, cellHeight: Int) -> CGSize? {
        guard let widest = idleBounds.map(\.width).max(),
              let tallest = idleBounds.map(\.height).max(),
              widest > 0, tallest > 0 else { return nil }
        return CGSize(
            width: min(widest, CGFloat(cellWidth) - 2 * margin),
            height: min(tallest, CGFloat(cellHeight) - margin - topSafety)
        )
    }

    static func scale(contentSize: CGSize, targetBox: CGSize, cellWidth: Int, cellHeight: Int) -> CGFloat? {
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        let usableWidth = CGFloat(cellWidth) - 2 * margin
        let usableHeight = CGFloat(cellHeight) - margin - topSafety
        let scale = min(
            targetBox.width / contentSize.width,
            targetBox.height / contentSize.height,
            usableWidth / contentSize.width,
            usableHeight / contentSize.height
        )
        return scale.isFinite && scale > 0 ? scale : nil
    }

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil ? true : defaults.bool(forKey: defaultsKey)
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}
