import Foundation

struct PetDescriptor: Equatable {
    let id: String
    let displayName: String
    let directory: URL
    let isBundled: Bool
}

struct LoadedPet {
    let descriptor: PetDescriptor
    let sheet: SpriteSheet
    let sleepAnimation: SleepAnimation?
}

struct PetCatalog {
    static let selectedPetKey = "AjmanSelectedPet"
    static let defaultPetID = "ajman"
    static let builtInRelativeScales: [String: Double] = ["ajman": 1.0, "winnie": 0.67]

    static func relativeScaleKey(for id: String) -> String {
        "AjmanPetScale.\(id)"
    }

    static func builtInRelativeScale(for id: String) -> Double {
        builtInRelativeScales[id] ?? 1.0
    }

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let liveRoot: URL
    private let bundledRoot: URL?

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        liveRoot: URL? = nil,
        bundledRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("pets", isDirectory: true)
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.liveRoot = liveRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
        self.bundledRoot = bundledRoot
    }

    var selectedPetID: String {
        defaults.string(forKey: Self.selectedPetKey) ?? Self.defaultPetID
    }

    func saveSelection(_ id: String) {
        defaults.set(id, forKey: Self.selectedPetKey)
    }

    func relativeScale(for id: String) -> Double {
        let key = Self.relativeScaleKey(for: id)
        if defaults.object(forKey: key) != nil {
            let value = defaults.double(forKey: key)
            if value.isFinite, value > 0 { return value }
        }
        return Self.builtInRelativeScale(for: id)
    }

    func saveRelativeScale(_ scale: Double, for id: String) {
        guard scale.isFinite, scale > 0 else { return }
        defaults.set(scale, forKey: Self.relativeScaleKey(for: id))
    }

    func discover() -> [PetDescriptor] {
        var petsByID: [String: PetDescriptor] = [:]
        // Bundled entries establish fallbacks; readable live packages with the same id take precedence.
        for descriptor in descriptors(in: bundledRoot, isBundled: true) { petsByID[descriptor.id] = descriptor }
        for descriptor in descriptors(in: liveRoot, isBundled: false) { petsByID[descriptor.id] = descriptor }
        return petsByID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func load(id: String, steadySize: Bool? = nil) throws -> LoadedPet {
        let candidates = descriptors(in: liveRoot, isBundled: false).filter { $0.id == id }
            + descriptors(in: bundledRoot, isBundled: true).filter { $0.id == id }
        guard !candidates.isEmpty else { throw SpriteSheetError.missingPackage(liveRoot.appendingPathComponent(id)) }
        var lastError: Error?
        for descriptor in candidates {
            do {
                return LoadedPet(
                    descriptor: descriptor,
                    sheet: try SpriteSheet.load(directory: descriptor.directory, steadySize: steadySize ?? SteadySize.load(from: defaults)),
                    sleepAnimation: loadSleepAnimation(for: id)
                )
            }
            catch {
                lastError = error
                log("pet '\(id)' failed from \(descriptor.directory.path): \(error.localizedDescription)")
            }
        }
        throw lastError ?? SpriteSheetError.missingPackage(liveRoot.appendingPathComponent(id))
    }

    func loadSelected() throws -> LoadedPet {
        let selected = selectedPetID
        do { return try load(id: selected) }
        catch { log("selected pet '\(selected)' failed; falling back to bundled ajman: \(error.localizedDescription)") }

        if let bundledRoot {
            let ajman = bundledRoot.appendingPathComponent(Self.defaultPetID, isDirectory: true)
            do {
                let descriptor = try descriptor(at: ajman, isBundled: true)
                return LoadedPet(
                    descriptor: descriptor,
                    sheet: try SpriteSheet.load(directory: ajman, steadySize: SteadySize.load(from: defaults)),
                    sleepAnimation: loadSleepAnimation(for: Self.defaultPetID)
                )
            } catch { log("bundled ajman fallback failed: \(error.localizedDescription)") }
        }
        return try load(id: Self.defaultPetID)
    }

    private func descriptors(in root: URL?, isBundled: Bool) -> [PetDescriptor] {
        guard let root,
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return directories.compactMap { try? descriptor(at: $0, isBundled: isBundled) }
    }

    private func descriptor(at directory: URL, isBundled: Bool) throws -> PetDescriptor {
        let manifestURL = directory.appendingPathComponent("pet.json")
        guard fileManager.isReadableFile(atPath: manifestURL.path) else {
            throw SpriteSheetError.missingPackage(directory)
        }
        struct Metadata: Decodable { let id: String?; let displayName: String?; let spritesheetPath: String? }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: manifestURL))
        let id = metadata.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = (id?.isEmpty == false ? id : nil) ?? directory.lastPathComponent
        let sheet = directory.appendingPathComponent(metadata.spritesheetPath ?? "spritesheet.webp")
        guard fileManager.isReadableFile(atPath: sheet.path) else { throw SpriteSheetError.missingPackage(directory) }
        let displayName = metadata.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PetDescriptor(
            id: resolvedID,
            displayName: (displayName?.isEmpty == false ? displayName : nil) ?? resolvedID.capitalized,
            directory: directory,
            isBundled: isBundled
        )
    }

    private func loadSleepAnimation(for id: String) -> SleepAnimation? {
        let candidates = [
            bundledRoot?.appendingPathComponent(id, isDirectory: true).appendingPathComponent("sleep.webp"),
            liveRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent("sleep.webp"),
        ].compactMap { $0 }
        for url in candidates where fileManager.isReadableFile(atPath: url.path) {
            // Ajman's seventh authored pose is the belly-up roly-poly: keep it
            // as an occasional treat while every other drowsy pose stays even.
            let poseWeights: [Double]? = id == "ajman"
                ? [1, 1, 1, 1, 1, 1, 0.3, 1]
                : nil
            do { return try SleepAnimation.load(from: url, poseWeights: poseWeights) }
            catch { log("pet '\(id)' sleep animation failed from \(url.path): \(error.localizedDescription)") }
        }
        return nil
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Ajman: \(message)\n".utf8))
    }
}
