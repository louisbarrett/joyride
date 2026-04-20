import Foundation
import Combine

/// Persists and publishes the set of mapping profiles. Profiles are stored as JSON in
/// `~/Library/Application Support/Lovejoy/profiles.json`.
final class ProfileStore: ObservableObject {
    struct PersistedData: Codable {
        var profiles: [MappingProfile]
        var activeProfileID: UUID
    }

    @Published private(set) var profiles: [MappingProfile] = []
    @Published private(set) var activeProfileID: UUID

    private let fileURL: URL
    private let io = DispatchQueue(label: "com.lovejoy.profilestore", qos: .utility)

    var activeProfile: MappingProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? MappingProfile.defaultScrollingProfile()
    }

    init(storageDirectory: URL? = nil) {
        let base = storageDirectory ?? ProfileStore.defaultStorageDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("profiles.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedData.self, from: data),
           !decoded.profiles.isEmpty {
            self.profiles = decoded.profiles
            self.activeProfileID = decoded.profiles.contains(where: { $0.id == decoded.activeProfileID })
                ? decoded.activeProfileID
                : decoded.profiles[0].id
        } else {
            let seeded = [
                MappingProfile.defaultScrollingProfile(),
                MappingProfile.defaultGamingProfile(),
                MappingProfile.defaultPresentationProfile()
            ]
            self.profiles = seeded
            self.activeProfileID = seeded[0].id
            persist()
        }
    }

    // MARK: - Public API

    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        persist()
    }

    func save(_ profile: MappingProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    func delete(_ id: UUID) {
        profiles.removeAll(where: { $0.id == id })
        if profiles.isEmpty {
            profiles = [MappingProfile.defaultScrollingProfile()]
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
        }
        persist()
    }

    func duplicate(_ id: UUID) {
        guard let src = profiles.first(where: { $0.id == id }) else { return }
        var copy = src
        copy.id = UUID()
        copy.name = "\(src.name) Copy"
        profiles.append(copy)
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let snapshot = PersistedData(profiles: profiles, activeProfileID: activeProfileID)
        let url = fileURL
        io.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Lovejoy: failed to persist profiles: %@", error.localizedDescription)
            }
        }
    }

    static func defaultStorageDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Lovejoy", isDirectory: true)
    }
}
