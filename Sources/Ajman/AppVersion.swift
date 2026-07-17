import Foundation

/// The version of the running Ajman build. Release tags may optionally begin with "v".
enum AjmanApp {
    static let version = AppVersion("0.1.1")!
    static let repository = "kvarnelis/ajman-mascot"
}

/// A deliberately forgiving SemVer-style value for comparing GitHub release tags.
struct AppVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        value = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let pieces = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericPieces = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !numericPieces.isEmpty,
              numericPieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        numbers = numericPieces.map { Int($0)! }
        prerelease = pieces.count == 2
            ? pieces[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            : []
    }

    var description: String {
        let base = numbers.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compareNumbers(lhs.numbers, rhs.numbers) == 0 && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let numberOrder = compareNumbers(lhs.numbers, rhs.numbers)
        if numberOrder != 0 { return numberOrder < 0 }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for index in 0..<max(lhs.prerelease.count, rhs.prerelease.count) {
            guard index < lhs.prerelease.count else { return true }
            guard index < rhs.prerelease.count else { return false }
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }
            if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
            if Int(left) != nil { return true }
            if Int(right) != nil { return false }
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        return false
    }

    private static func compareNumbers(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs < rhs ? -1 : 1 }
        }
        return 0
    }
}
