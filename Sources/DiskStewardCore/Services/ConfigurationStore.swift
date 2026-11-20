import Foundation

/// Persists application configuration, deferred archive runs, verified archive records, and run history as JSON.
public final class ConfigurationStore: Sendable {
    public let fileURL: URL

    public init(directoryURL: URL? = nil, fileName: String = "state.json") {
        let baseDir: URL
        if let directoryURL {
            baseDir = directoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            baseDir = appSupport.appendingPathComponent("DiskSteward", isDirectory: true)
        }
        self.fileURL = baseDir.appendingPathComponent(fileName)
    }

    public func load() -> PersistedAppState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return PersistedAppState()
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedAppState.self, from: data)
        } catch {
            return PersistedAppState()
        }
    }

    public func save(_ state: PersistedAppState) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}
