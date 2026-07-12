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
    case lookDirectionsA = "look-directions-a"
    case lookDirectionsB = "look-directions-b"

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
        case .lookDirectionsA: "Look Directions A"
        case .lookDirectionsB: "Look Directions B"
        }
    }
}

struct AnimationDefinition {
    let state: AnimationState
    let row: Int
    let durations: [TimeInterval]

    var frameCount: Int { durations.count }
}

struct AnimationTable {
    let spriteVersionNumber: Int
    let definitions: [AnimationDefinition]

    var states: [AnimationState] { definitions.map(\.state) }
    var usedFrameCount: Int { definitions.reduce(0) { $0 + $1.frameCount } }

    func definition(for state: AnimationState) -> AnimationDefinition? {
        definitions.first { $0.state == state }
    }

    static func forVersion(_ version: Int) throws -> AnimationTable {
        switch version {
        case 1: .v1
        case 2: .v2
        default: throw SpriteSheetError.unknownVersion(version)
        }
    }

    // Keep the established v1 timings byte-for-byte equivalent: idle is played
    // six times slower than the authored per-frame durations.
    static let v1 = AnimationTable(spriteVersionNumber: 1, definitions: [
        definition(.idle, row: 0, milliseconds: [280, 110, 110, 140, 140, 320].map { $0 * 6 }),
        definition(.runningRight, row: 1, milliseconds: [120, 120, 120, 120, 120, 120, 120, 220]),
        definition(.runningLeft, row: 2, milliseconds: [120, 120, 120, 120, 120, 120, 120, 220]),
        definition(.waving, row: 3, milliseconds: [140, 140, 140, 280]),
        definition(.jumping, row: 4, milliseconds: [140, 140, 140, 140, 280]),
        definition(.failed, row: 5, milliseconds: [140, 140, 140, 140, 140, 140, 140, 240]),
        definition(.waiting, row: 6, milliseconds: [150, 150, 150, 150, 150, 260]),
        definition(.running, row: 7, milliseconds: [120, 120, 120, 120, 120, 220]),
        definition(.review, row: 8, milliseconds: [150, 150, 150, 150, 150, 280]),
    ])

    static let v2 = AnimationTable(spriteVersionNumber: 2, definitions: [
        definition(.idle, row: 0, milliseconds: [280, 110, 110, 140, 140, 320].map { $0 * 6 }),
        definition(.runningRight, row: 1, milliseconds: [120, 120, 120, 120, 120, 120, 120, 220]),
        definition(.runningLeft, row: 2, milliseconds: [120, 120, 120, 120, 120, 120, 120, 220]),
        definition(.waving, row: 3, milliseconds: [140, 140, 140, 280]),
        definition(.jumping, row: 4, milliseconds: [140, 140, 140, 140, 280]),
        definition(.failed, row: 5, milliseconds: [140, 140, 140, 140, 140, 140, 140, 240]),
        definition(.waiting, row: 6, milliseconds: [150, 150, 150, 150, 150, 260]),
        definition(.running, row: 7, milliseconds: [120, 120, 120, 120, 120, 220]),
        definition(.review, row: 8, milliseconds: [150, 150, 150, 150, 150, 280]),
        definition(.lookDirectionsA, row: 9, milliseconds: Array(repeating: 150, count: 8)),
        definition(.lookDirectionsB, row: 10, milliseconds: Array(repeating: 150, count: 8)),
    ])

    private static func definition(
        _ state: AnimationState,
        row: Int,
        milliseconds: [Int]
    ) -> AnimationDefinition {
        AnimationDefinition(
            state: state,
            row: row,
            durations: milliseconds.map { TimeInterval($0) / 1_000 }
        )
    }
}
