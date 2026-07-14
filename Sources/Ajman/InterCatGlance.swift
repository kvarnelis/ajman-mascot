import AppKit

struct LookDirection: Equatable {
    static let headingStep = 22.5

    let headingIndex: Int

    var headingDegrees: Double { Double(headingIndex) * Self.headingStep }
    var state: AnimationState { headingIndex < 8 ? .lookDirectionsA : .lookDirectionsB }
    var frameIndex: Int { headingIndex % 8 }

    static func toward(source: NSPoint, target: NSPoint) -> LookDirection? {
        let dx = target.x - source.x
        let dy = target.y - source.y
        guard abs(dx) > .ulpOfOne || abs(dy) > .ulpOfOne else { return nil }

        // Compass convention for the authored rows: 000° is screen-up and
        // angles increase clockwise, so atan2 takes x before y here.
        var degrees = atan2(Double(dx), Double(dy)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let headingIndex = Int((degrees / Self.headingStep).rounded()) % 16
        return LookDirection(headingIndex: headingIndex)
    }
}

struct InterCatGlanceEligibility {
    let isShown: Bool
    let supportsLookDirections: Bool
    let liveState: AnimationState
    let displayedState: AnimationState
    let isManual: Bool
    let isSleeping: Bool
    let isAlreadyGlancing: Bool

    var canReact: Bool {
        isShown
            && supportsLookDirections
            && liveState == .idle
            && displayedState == .idle
            && !isManual
            && !isSleeping
            && !isAlreadyGlancing
    }
}

@MainActor
struct InterCatGlanceCandidate {
    let petID: String
    let temperament: () -> Temperament
    let isEligible: () -> Bool
    let requestGlance: (NSPoint) -> Bool

    init(
        petID: String,
        temperament: @escaping () -> Temperament = { .normal },
        isEligible: @escaping () -> Bool,
        requestGlance: @escaping (NSPoint) -> Bool
    ) {
        self.petID = petID
        self.temperament = temperament
        self.isEligible = isEligible
        self.requestGlance = requestGlance
    }
}

@MainActor
final class InterCatGlanceCoordinator {
    nonisolated static let defaultProbability = 0.6
    nonisolated static let defaultCooldown: TimeInterval = 8

    private let probability: Double
    private let cooldown: TimeInterval
    private let now: () -> Date
    private let randomUnit: () -> Double
    private var lastGlanceByPetID: [String: Date] = [:]

    init(
        probability: Double = InterCatGlanceCoordinator.defaultProbability,
        cooldown: TimeInterval = InterCatGlanceCoordinator.defaultCooldown,
        now: @escaping () -> Date = Date.init,
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.probability = min(max(probability, 0), 1)
        self.cooldown = max(cooldown, 0)
        self.now = now
        self.randomUnit = randomUnit
    }

    func livelyAnimationBegan(
        sourcePetID: String,
        sourceCenter: NSPoint,
        candidates: [InterCatGlanceCandidate]
    ) {
        let timestamp = now()
        for candidate in candidates where candidate.petID != sourcePetID {
            guard candidate.isEligible() else { continue }
            let temperament = candidate.temperament()
            if let lastGlance = lastGlanceByPetID[candidate.petID],
               timestamp.timeIntervalSince(lastGlance) < temperament.scaled(interval: cooldown) {
                continue
            }
            guard randomUnit() < temperament.scaled(probability: probability) else { continue }
            if candidate.requestGlance(sourceCenter) {
                lastGlanceByPetID[candidate.petID] = timestamp
            }
        }
    }
}
