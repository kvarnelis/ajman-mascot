import AppKit

enum PetClickDisposition: Equatable {
    case normal
    case advanceAction

    static func classify(buttonNumber: Int, modifiers: NSEvent.ModifierFlags) -> PetClickDisposition {
        if buttonNumber == 1 || (buttonNumber == 0 && modifiers.contains(.control)) {
            return .advanceAction
        }
        return .normal
    }
}

enum PetCycleAction: Equatable {
    case animation(AnimationState)
    case loaf
    case sleep
    case scratch
    case groom
}

enum PetActionCycle {
    /// State-only order used by the status-menu cycle.
    static let order = AnimationState.allCases

    /// Full order used by direct per-pet control/right-click cycling.
    static let directOrder: [PetCycleAction] =
        AnimationState.allCases.map(PetCycleAction.animation) + [.loaf, .sleep, .scratch, .groom]

    static func next(after current: AnimationState?, availableStates: [AnimationState]) -> AnimationState? {
        let available = Set(availableStates)
        let cycle = order.filter(available.contains)
        guard !cycle.isEmpty else { return nil }
        guard let current, let index = cycle.firstIndex(of: current) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }

    static func availableActions(
        availableStates: [AnimationState],
        hasLoaf: Bool,
        hasSleep: Bool,
        hasScratch: Bool,
        hasGroom: Bool = false
    ) -> [PetCycleAction] {
        let states = Set(availableStates)
        return directOrder.filter { action in
            switch action {
            case let .animation(state): states.contains(state)
            case .loaf: hasLoaf
            case .sleep: hasSleep
            case .scratch: hasScratch
            case .groom: hasGroom
            }
        }
    }

    struct Cursor {
        private(set) var position: Int?
        private var lastAction: PetCycleAction?

        mutating func next(
            availableActions: [PetCycleAction],
            startingAfter initialAction: PetCycleAction? = nil
        ) -> PetCycleAction? {
            guard !availableActions.isEmpty else {
                position = nil
                lastAction = nil
                return nil
            }

            let nextPosition: Int
            if let lastAction, let previous = availableActions.firstIndex(of: lastAction) {
                nextPosition = (previous + 1) % availableActions.count
            } else if lastAction != nil, let position {
                // If the pet's available set changed and removed the last action,
                // its old ordinal now points at the sensible following action.
                nextPosition = position % availableActions.count
            } else if let initialAction, let initial = availableActions.firstIndex(of: initialAction) {
                nextPosition = (initial + 1) % availableActions.count
            } else {
                nextPosition = 0
            }

            position = nextPosition
            lastAction = availableActions[nextPosition]
            return lastAction
        }
    }
}
