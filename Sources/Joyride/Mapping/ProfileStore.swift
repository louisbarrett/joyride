import Foundation
import Combine

/// Persists and publishes the set of mapping profiles. Profiles are stored as JSON in
/// `~/Library/Application Support/Joyride/profiles.json`.
///
/// Writes are debounced: typing in a name field or dragging a slider rebinds the profile
/// many times per second, and encoding + atomic-writing JSON on every keystroke was a
/// significant source of main-thread backpressure in earlier builds. We now coalesce
/// writes on a utility queue with a short delay and flush synchronously on app exit.
final class ProfileStore: ObservableObject {
    struct PersistedData: Codable {
        var profiles: [MappingProfile]
        var activeProfileID: UUID
    }

    @Published private(set) var profiles: [MappingProfile] = []
    @Published private(set) var activeProfileID: UUID

    private let fileURL: URL
    private let io = DispatchQueue(label: "com.joyride.profilestore", qos: .utility)

    /// Coalescing window — rapid edits within this interval share a single disk write.
    private let persistDelay: TimeInterval = 0.3
    /// The latest scheduled write. Cancelled & replaced on each edit so we only hit disk
    /// once per burst.
    private var pendingPersist: DispatchWorkItem?
    /// Guards `pendingPersist` against concurrent access between main (scheduling) and the
    /// IO queue (executing).
    private let pendingLock = NSLock()

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
            // Seeded data is stable — write it out immediately so we don't wait the
            // debounce interval on very first launch.
            persistNow()
        }
    }

    // MARK: - Public API

    func setActive(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        schedulePersist()
    }

    func save(_ profile: MappingProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            // Skip the @Published mutation if nothing actually changed. This is the hot
            // path for slider drags and text-field typing — suppressing no-op writes
            // avoids needlessly rebuilding any view that observes `profiles`.
            if profiles[idx] == profile { return }
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        schedulePersist()
    }

    func delete(_ id: UUID) {
        profiles.removeAll(where: { $0.id == id })
        if profiles.isEmpty {
            profiles = [MappingProfile.defaultScrollingProfile()]
        }
        if !profiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = profiles[0].id
        }
        schedulePersist()
    }

    func duplicate(_ id: UUID) {
        guard let src = profiles.first(where: { $0.id == id }) else { return }
        var copy = src
        copy.id = UUID()
        copy.name = "\(src.name) Copy"
        profiles.append(copy)
        schedulePersist()
    }

    /// Synchronously write any pending changes. Call from `applicationWillTerminate` so
    /// the user never loses recent edits if they quit inside the debounce window.
    func flushPendingWrites() {
        pendingLock.lock()
        let item = pendingPersist
        pendingPersist = nil
        pendingLock.unlock()
        item?.cancel()
        persistNow()
    }

    // MARK: - Persistence

    /// Schedule a debounced persist. Safe to call many times per second — only the last
    /// call within `persistDelay` actually touches disk.
    private func schedulePersist() {
        pendingLock.lock()
        pendingPersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.persistNow()
        }
        pendingPersist = item
        pendingLock.unlock()
        io.asyncAfter(deadline: .now() + persistDelay, execute: item)
    }

    private func persistNow() {
        // Snapshot on caller's thread (main when invoked from SwiftUI bindings, IO
        // queue when invoked from the debounced work item). Copying the Codable
        // structures is cheap and avoids any cross-thread access to @Published state.
        let snapshot = PersistedData(profiles: profiles, activeProfileID: activeProfileID)
        let url = fileURL
        // The actual file write goes to the IO queue regardless so we never block
        // SwiftUI bindings on disk.
        io.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("Joyride: failed to persist profiles: %@", error.localizedDescription)
            }
        }
    }

    static func defaultStorageDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Joyride", isDirectory: true)
    }
}
