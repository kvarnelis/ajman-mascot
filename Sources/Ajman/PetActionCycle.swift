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

enum PetActionCycle {
    /// Shared by the status-menu cycle and direct per-pet cycling.
    static let order = AnimationState.allCases

    static func next(after current: AnimationState?, availableStates: [AnimationState]) -> AnimationState? {
        let available = Set(availableStates)
        let cycle = order.filter(available.contains)
        guard !cycle.isEmpty else { return nil }
        guard let current, let index = cycle.firstIndex(of: current) else { return cycle[0] }
        return cycle[(index + 1) % cycle.count]
    }
}
