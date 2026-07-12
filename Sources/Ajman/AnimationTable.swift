import Foundation

enum AnimationState: String, CaseIterable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review

    var row: Int { Self.allCases.firstIndex(of: self)! }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .runningRight: "Running Right"
        case .runningLeft: "Running Left"
        case .waving: "Waving"
        case .jumping: "Jumping"
        case .failed: "Failed"
        case .waiting: "Waiting"
        case .running: "Running"
        case .review: "Review"
        }
    }

    var durations: [TimeInterval] {
        let milliseconds: [Int]
        switch self {
        case .idle: milliseconds = [280, 110, 110, 140, 140, 320].map { $0 * 6 }
        case .runningRight, .runningLeft: milliseconds = [120, 120, 120, 120, 120, 120, 120, 220]
        case .waving: milliseconds = [140, 140, 140, 280]
        case .jumping: milliseconds = [140, 140, 140, 140, 280]
        case .failed: milliseconds = [140, 140, 140, 140, 140, 140, 140, 240]
        case .waiting: milliseconds = [150, 150, 150, 150, 150, 260]
        case .running: milliseconds = [120, 120, 120, 120, 120, 220]
        case .review: milliseconds = [150, 150, 150, 150, 150, 280]
        }
        return milliseconds.map { TimeInterval($0) / 1_000 }
    }

    static let usedFrameCount = allCases.reduce(0) { $0 + $1.durations.count }
}
