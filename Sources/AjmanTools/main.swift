import CoreGraphics
import Foundation
import ImageIO

private struct Raster {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, fill: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
        if fill != (0, 0, 0, 0) {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = fill.0; pixels[i + 1] = fill.1
                pixels[i + 2] = fill.2; pixels[i + 3] = fill.3
            }
        }
    }

    subscript(x: Int, y: Int, channel: Int) -> UInt8 {
        get { pixels[(y * width + x) * 4 + channel] }
        set { pixels[(y * width + x) * 4 + channel] = newValue }
    }
}

private enum ToolError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case let .message(text): return text }
    }
}

private func decode(_ url: URL) throws -> Raster {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ToolError.message("Could not decode \(url.path)")
    }
    var raster = Raster(width: image.width, height: image.height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ok = raster.pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard let base = bytes.baseAddress,
              let context = CGContext(data: base, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard ok else { throw ToolError.message("Could not create RGBA bitmap for \(url.path)") }
    return raster
}

private func makeImage(_ raster: Raster) throws -> CGImage {
    let data = Data(raster.pixels) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(width: raster.width, height: raster.height,
                              bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: raster.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true,
                              intent: .defaultIntent) else {
        throw ToolError.message("Could not create output image")
    }
    return image
}

private func write(_ raster: Raster, to url: URL, type: CFString) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
        throw ToolError.message("Could not create image destination \(url.path)")
    }
    CGImageDestinationAddImage(destination, try makeImage(raster), nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ToolError.message("Could not write \(url.path)")
    }
}

// Deliberately conservative: pure and noisy greens key out, while yellow-green eyes remain.
private func isBackground(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool {
    Int(g) > 90 && Int(g) > Int(r) + 60 && Int(g) > Int(b) + 60
}

private struct Box: Codable { let x: Int; let y: Int; let w: Int; let h: Int }
private struct SegmentFrame: Codable { let index: Int; let bbox: Box; let outFile: String }
private struct SegmentIndex: Codable { let source: String; let frames: [SegmentFrame] }

private func segment(stripURL: URL, outURL: URL) throws {
    let source = try decode(stripURL)
    var background = [Bool](repeating: false, count: source.width * source.height)
    for y in 0..<source.height {
        for x in 0..<source.width {
            background[y * source.width + x] = isBackground(source[x, y, 0], source[x, y, 1], source[x, y, 2])
        }
    }
    var runs: [Range<Int>] = []
    var start: Int?
    for x in 0...source.width {
        let nonEmpty: Bool
        if x == source.width { nonEmpty = false }
        else {
            var bg = 0
            for y in 0..<source.height where background[y * source.width + x] { bg += 1 }
            nonEmpty = Double(bg) / Double(source.height) < 0.995
        }
        if nonEmpty && start == nil { start = x }
        if !nonEmpty, let s = start {
            if x - s >= 40 { runs.append(s..<x) }
            start = nil
        }
    }
    guard !runs.isEmpty else { throw ToolError.message("No frames found in \(stripURL.path)") }
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    var records: [SegmentFrame] = []
    for (index, run) in runs.enumerated() {
        var minX = run.upperBound, maxX = run.lowerBound, minY = source.height, maxY = -1
        for y in 0..<source.height {
            for x in run where !background[y * source.width + x] {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxY >= minY else { continue }
        minX = max(0, minX - 4); minY = max(0, minY - 4)
        maxX = min(source.width - 1, maxX + 4); maxY = min(source.height - 1, maxY + 4)
        let box = Box(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)
        var frame = Raster(width: box.w, height: box.h)
        for y in 0..<box.h {
            for x in 0..<box.w {
                let sx = box.x + x, sy = box.y + y
                let r = source[sx, sy, 0], g = source[sx, sy, 1], b = source[sx, sy, 2]
                if background[sy * source.width + sx] {
                    frame[x, y, 0] = 0; frame[x, y, 1] = 0; frame[x, y, 2] = 0; frame[x, y, 3] = 0
                } else {
                    frame[x, y, 0] = r
                    frame[x, y, 1] = g > max(r, b) ? max(r, b) : g
                    frame[x, y, 2] = b
                    frame[x, y, 3] = 255
                }
            }
        }
        let filename = String(format: "frame-%02d.png", index)
        try write(frame, to: outURL.appendingPathComponent(filename), type: "public.png" as CFString)
        records.append(SegmentFrame(index: index, bbox: box, outFile: filename))
    }
    let record = SegmentIndex(source: stripURL.path, frames: records)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(record).write(to: outURL.appendingPathComponent("index.json"))
    print("segment: \(stripURL.lastPathComponent): \(records.count) frames")
}

private struct V1Cell: Codable { let row: Int; let col: Int }
private struct Cell: Codable {
    let row: Int; let col: Int; let from: String?; let v1: V1Cell?; let empty: Bool?
}
private struct Manifest: Codable {
    let cellWidth: Int; let cellHeight: Int; let columns: Int; let rows: Int
    let v1Sheet: String; let cells: [Cell]
}

private func alphaBounds(_ raster: Raster) -> Box? {
    var minX = raster.width, maxX = -1, minY = raster.height, maxY = -1
    for y in 0..<raster.height { for x in 0..<raster.width where raster[x, y, 3] > 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }}
    return maxX < minX ? nil : Box(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)
}

private func alphaBounds(_ raster: Raster, within box: Box) -> Box? {
    var minX = box.x + box.w, maxX = box.x - 1, minY = box.y + box.h, maxY = box.y - 1
    for y in box.y..<(box.y + box.h) { for x in box.x..<(box.x + box.w) where raster[x, y, 3] > 0 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }}
    return maxX < minX ? nil : Box(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)
}

private func median(_ values: [Int]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return Double(sorted[middle]) }
    return Double(sorted[middle - 1] + sorted[middle]) / 2
}

private struct StripNormalization {
    let medianHeight: Double
    let desiredFactor: Double
    let factor: Double
    let capDescription: String?
}

private func blit(_ source: Raster, sourceBox: Box, into target: inout Raster,
                  destX: Int, destY: Int, destW: Int, destH: Int) {
    guard destW > 0, destH > 0 else { return }
    for dy in 0..<destH {
        let sy = sourceBox.y + min(sourceBox.h - 1, Int(Double(dy) * Double(sourceBox.h) / Double(destH)))
        for dx in 0..<destW {
            let sx = sourceBox.x + min(sourceBox.w - 1, Int(Double(dx) * Double(sourceBox.w) / Double(destW)))
            let tx = destX + dx, ty = destY + dy
            guard tx >= 0, tx < target.width, ty >= 0, ty < target.height else { continue }
            for c in 0..<4 { target[tx, ty, c] = source[sx, sy, c] }
        }
    }
}

private let glyphs: [Character: [UInt8]] = [
    "A":[14,17,17,31,17,17,17], "D":[30,17,17,17,17,17,30], "E":[31,16,16,30,16,16,31],
    "F":[31,16,16,30,16,16,16], "G":[14,17,16,23,17,17,14], "I":[31,4,4,4,4,4,31],
    "J":[7,2,2,2,18,18,12], "K":[17,18,20,24,20,18,17], "L":[16,16,16,16,16,16,31],
    "M":[17,27,21,21,17,17,17],
    "N":[17,25,21,21,19,17,17], "O":[14,17,17,17,17,17,14], "P":[30,17,17,30,16,16,16],
    "R":[30,17,17,30,20,18,17], "T":[31,4,4,4,4,4,4], "U":[17,17,17,17,17,17,14], "V":[17,17,17,17,17,10,4],
    "W":[17,17,17,21,21,21,10], "-":[0,0,0,31,0,0,0], " ":[0,0,0,0,0,0,0]
]

private func drawText(_ text: String, x: Int, y: Int, scale: Int, into image: inout Raster) {
    var cursor = x
    for ch in text.uppercased() {
        let rows = glyphs[ch] ?? glyphs[" "]!
        for (gy, bits) in rows.enumerated() { for gx in 0..<5 where bits & (1 << (4 - gx)) != 0 {
            for py in 0..<scale { for px in 0..<scale {
                let xx = cursor + gx * scale + px, yy = y + gy * scale + py
                if xx >= 0, yy >= 0, xx < image.width, yy < image.height {
                    image[xx, yy, 0] = 255; image[xx, yy, 1] = 255; image[xx, yy, 2] = 255; image[xx, yy, 3] = 255
                }
            }}
        }}
        cursor += 6 * scale
    }
}

private func makePreview(atlas: Raster, cellW: Int, cellH: Int, columns: Int, rows: Int) -> Raster {
    let scale = 2, labelWidth = 180
    var result = Raster(width: atlas.width * scale + labelWidth, height: atlas.height * scale, fill: (30, 30, 30, 255))
    let full = Box(x: 0, y: 0, w: atlas.width, h: atlas.height)
    blit(atlas, sourceBox: full, into: &result, destX: labelWidth, destY: 0,
         destW: atlas.width * scale, destH: atlas.height * scale)
    let labels = ["IDLE", "RUN-R", "RUN-L", "WAVE", "JUMP", "FAILED", "WAITING", "WORKING", "REVIEW"]
    for row in 0..<rows {
        let yy = row * cellH * scale
        drawText(labels[row], x: 8, y: yy + cellH * scale / 2 - 14, scale: 3, into: &result)
        for x in labelWidth..<result.width { for t in 0..<2 { result[x, min(result.height - 1, yy + t), 0] = 255; result[x, min(result.height - 1, yy + t), 1] = 255; result[x, min(result.height - 1, yy + t), 2] = 255; result[x, min(result.height - 1, yy + t), 3] = 180 } }
    }
    for col in 0...columns {
        let xx = min(result.width - 1, labelWidth + col * cellW * scale)
        for y in 0..<result.height { for t in 0..<2 where xx + t < result.width {
            result[xx + t, y, 0] = 255; result[xx + t, y, 1] = 255; result[xx + t, y, 2] = 255; result[xx + t, y, 3] = 180
        }}
    }
    return result
}

private func compose(manifestURL: URL, outURL: URL) throws {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.cellWidth == 192, manifest.cellHeight == 208, manifest.columns == 8, manifest.rows == 9 else {
        throw ToolError.message("Manifest must describe the standard 8x9 atlas with 192x208 cells")
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let v1URL = URL(fileURLWithPath: manifest.v1Sheet, relativeTo: cwd).standardizedFileURL
    let v1 = try decode(v1URL)
    guard v1.width == 1536, v1.height == 1872 else { throw ToolError.message("v1 sheet has unexpected dimensions") }
    var v1Heights: [Int] = []
    for cell in manifest.cells { if let sourceCell = cell.v1 {
        guard sourceCell.row >= 0, sourceCell.row < 9, sourceCell.col >= 0, sourceCell.col < 8 else {
            throw ToolError.message("v1 source cell outside atlas")
        }
        let cellBox = Box(x: sourceCell.col * manifest.cellWidth, y: sourceCell.row * manifest.cellHeight,
                          w: manifest.cellWidth, h: manifest.cellHeight)
        guard let bounds = alphaBounds(v1, within: cellBox) else {
            throw ToolError.message("v1 source cell is empty: row \(sourceCell.row), col \(sourceCell.col)")
        }
        v1Heights.append(bounds.h)
    }}
    let targetHeight = median(v1Heights) ?? 196

    var loaded: [String: (Raster, Box)] = [:]
    var pathsByStrip: [String: [String]] = [:]
    for cell in manifest.cells { if let path = cell.from, loaded[path] == nil {
        let raster = try decode(URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL)
        guard let bounds = alphaBounds(raster) else { throw ToolError.message("Source frame is empty: \(path)") }
        loaded[path] = (raster, bounds)
    }}
    for cell in manifest.cells { if let path = cell.from {
        let strip = (path as NSString).deletingLastPathComponent
        pathsByStrip[strip, default: []].append(path)
    }}
    var normalizations: [String: StripNormalization] = [:]
    for (strip, paths) in pathsByStrip {
        let bounds = paths.compactMap { loaded[$0]?.1 }
        guard let medianHeight = median(bounds.map(\.h)) else { continue }
        let desiredFactor = targetHeight / medianHeight
        let widthCap = bounds.map { Double(manifest.cellWidth) / Double($0.w) }.min() ?? desiredFactor
        let heightCap = bounds.map { Double(manifest.cellHeight - 4) / Double($0.h) }.min() ?? desiredFactor
        let factor = min(desiredFactor, widthCap, heightCap)
        var capParts: [String] = []
        if widthCap + 0.0000001 < desiredFactor && widthCap <= heightCap + 0.0000001 { capParts.append("width") }
        if heightCap + 0.0000001 < desiredFactor && heightCap <= widthCap + 0.0000001 { capParts.append("height/4px margin") }
        normalizations[strip] = StripNormalization(
            medianHeight: medianHeight, desiredFactor: desiredFactor, factor: factor,
            capDescription: capParts.isEmpty ? nil : capParts.joined(separator: "+"))
    }
    var atlas = Raster(width: manifest.cellWidth * manifest.columns, height: manifest.cellHeight * manifest.rows)
    var explicitlyFilled = Set<Int>()
    for cell in manifest.cells {
        guard cell.row >= 0, cell.row < manifest.rows, cell.col >= 0, cell.col < manifest.columns else {
            throw ToolError.message("Cell outside atlas: row \(cell.row), col \(cell.col)")
        }
        let choices = (cell.from == nil ? 0 : 1) + (cell.v1 == nil ? 0 : 1) + (cell.empty == true ? 1 : 0)
        guard choices == 1 else { throw ToolError.message("Each cell needs exactly one of from, v1, or empty") }
        let key = cell.row * manifest.columns + cell.col
        guard !explicitlyFilled.contains(key) else { throw ToolError.message("Duplicate cell row \(cell.row), col \(cell.col)") }
        explicitlyFilled.insert(key)
        let originX = cell.col * manifest.cellWidth, originY = cell.row * manifest.cellHeight
        if let path = cell.from, let (source, bounds) = loaded[path] {
            let strip = (path as NSString).deletingLastPathComponent
            guard let normalization = normalizations[strip] else {
                throw ToolError.message("Missing normalization for source strip: \(strip)")
            }
            let w = Int((Double(bounds.w) * normalization.factor).rounded())
            let h = Int((Double(bounds.h) * normalization.factor).rounded())
            guard w <= manifest.cellWidth, h <= manifest.cellHeight - 4 else {
                throw ToolError.message("Strip scale makes \(path) \(w)x\(h), too large for a cell")
            }
            blit(source, sourceBox: bounds, into: &atlas,
                 destX: originX + (manifest.cellWidth - w) / 2,
                 destY: originY + manifest.cellHeight - 4 - h, destW: w, destH: h)
        } else if let sourceCell = cell.v1 {
            guard sourceCell.row >= 0, sourceCell.row < 9, sourceCell.col >= 0, sourceCell.col < 8 else {
                throw ToolError.message("v1 source cell outside atlas")
            }
            blit(v1, sourceBox: Box(x: sourceCell.col * 192, y: sourceCell.row * 208, w: 192, h: 208),
                 into: &atlas, destX: originX, destY: originY, destW: 192, destH: 208)
        }
    }
    let required = [6, 8, 8, 4, 5, 8, 6, 6, 6]
    var violations: [String] = []
    for row in 0..<required.count { for col in 0..<required[row] {
        var nonempty = false
        for y in row * manifest.cellHeight..<(row + 1) * manifest.cellHeight {
            for x in col * manifest.cellWidth..<(col + 1) * manifest.cellWidth where atlas[x, y, 3] > 0 { nonempty = true; break }
            if nonempty { break }
        }
        if !nonempty { violations.append("row \(row) col \(col)") }
    }}
    if !violations.isEmpty {
        fputs("WARNING: REQUIRED CELLS EMPTY: \(violations.joined(separator: ", "))\n", stderr)
        throw ToolError.message("Compose validation failed: required cells are empty")
    }
    try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
    try write(atlas, to: outURL.appendingPathComponent("spritesheet.png"), type: "public.png" as CFString)
    let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    let webpAvailable = identifiers.contains("org.webmproject.webp")
    if webpAvailable {
        try write(atlas, to: outURL.appendingPathComponent("spritesheet.webp"), type: "org.webmproject.webp" as CFString)
        print("compose: WebP encoding available; wrote spritesheet.webp")
    } else { print("compose: WebP encoding unavailable; skipped spritesheet.webp") }
    try write(makePreview(atlas: atlas, cellW: manifest.cellWidth, cellH: manifest.cellHeight,
                          columns: manifest.columns, rows: manifest.rows),
              to: outURL.appendingPathComponent("preview.png"), type: "public.png" as CFString)
    print(String(format: "compose: v1 target content height %.2f px%@", targetHeight,
                 v1Heights.isEmpty ? " (default; no v1 cells)" : ""))
    for strip in normalizations.keys.sorted() { if let normalization = normalizations[strip] {
        let cap = normalization.capDescription.map {
            String(format: "; CAP HIT (%@), requested %.6f", $0, normalization.desiredFactor)
        } ?? "; no cap"
        print(String(format: "compose: strip %@ median %.2f px; factor %.6f%@",
                     strip, normalization.medianHeight, normalization.factor, cap))
    }}
    print("compose: validation passed; 57 required cells filled")
    print("compose: wrote spritesheet.png \(atlas.width)x\(atlas.height) and preview.png")
}

private func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 3 else { throw ToolError.message("Usage: ajman-tools segment <strip.png> <outdir>\n       ajman-tools compose <manifest.json> <outdir>") }
    switch args[0] {
    case "segment": try segment(stripURL: URL(fileURLWithPath: args[1]), outURL: URL(fileURLWithPath: args[2]))
    case "compose": try compose(manifestURL: URL(fileURLWithPath: args[1]), outURL: URL(fileURLWithPath: args[2]))
    default: throw ToolError.message("Unknown subcommand: \(args[0])")
    }
}

do { try main() }
catch { fputs("ajman-tools: \(error)\n", stderr); exit(1) }
