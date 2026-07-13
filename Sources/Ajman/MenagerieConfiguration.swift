import Foundation

enum PetBinding: String, CaseIterable {
    case claude
    case codex
    case both

    var provider: AgentEvent.Provider? {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .both: nil
        }
    }

    var menuTitle: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .both: "Both"
        }
    }

    init(provider: AgentEvent.Provider?) {
        switch provider {
        case .claude: self = .claude
        case .codex: self = .codex
        case nil: self = .both
        }
    }
}

struct MenagerieConfiguration {
    static let shownPetsKey = "AjmanShownPets"
    static let bindingKeyPrefix = "AjmanPetBinding."
    static let firstRunShownPets: Set<String> = ["ajman", "winnie"]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shownPetIDs: Set<String> {
        guard defaults.object(forKey: Self.shownPetsKey) != nil else {
            return Self.firstRunShownPets
        }
        return Set(defaults.stringArray(forKey: Self.shownPetsKey) ?? [])
    }

    func setShown(_ shown: Bool, petID: String) {
        var ids = shownPetIDs
        if shown { ids.insert(petID) } else { ids.remove(petID) }
        defaults.set(ids.sorted(), forKey: Self.shownPetsKey)
    }

    func binding(for petID: String) -> AgentEvent.Provider? {
        if let raw = defaults.string(forKey: Self.bindingKeyPrefix + petID),
           let binding = PetBinding(rawValue: raw) {
            return binding.provider
        }
        switch petID {
        case "ajman": return .claude
        case "winnie": return .codex
        default: return nil
        }
    }

    func setBinding(_ provider: AgentEvent.Provider?, for petID: String) {
        defaults.set(PetBinding(provider: provider).rawValue, forKey: Self.bindingKeyPrefix + petID)
    }
}
