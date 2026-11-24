import Foundation

public enum NoteStoreError: LocalizedError {
    case storageUnavailable
    case unsupportedVersion(Int)
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "Stick could not locate your Application Support folder."
        case .unsupportedVersion(let version):
            return "These notes use storage version \(version), which this version of Stick cannot read. Your file has not been changed."
        case .invalidFile(let reason):
            return "Stick could not read its saved notes. Your file has not been changed. \(reason)"
        }
    }
}

/// Used on the application's main thread. Each mutation writes atomically before
/// publishing the in-memory result, so a failed save cannot masquerade as success.
public final class NoteStore {
    public private(set) var notes: [StickNote]
    public let fileURL: URL

    private struct Envelope: Codable {
        let version: Int
        let notes: [StickNote]
    }
    private struct Version: Decodable { let version: Int }

    public init(directory suppliedDirectory: URL? = nil) throws {
        let directory: URL
        if let supplied = suppliedDirectory {
            directory = supplied
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw NoteStoreError.storageUnavailable
            }
            directory = support.appendingPathComponent("Stick", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("notes.json")
        notes = try Self.load(fileURL)
    }

    public func upsert(_ note: StickNote) throws {
        var next = notes.filter { $0.id != note.id }
        next.append(note)
        try persist(next)
    }

    public func delete(id: UUID) throws {
        try persist(notes.filter { $0.id != id })
    }

    private static func sorted(_ notes: [StickNote]) -> [StickNote] {
        notes.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func load(_ url: URL) throws -> [StickNote] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(Version.self, from: data).version
            guard version == 1 else { throw NoteStoreError.unsupportedVersion(version) }
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard Set(envelope.notes.map(\.id)).count == envelope.notes.count else {
                throw NoteStoreError.invalidFile("The file contains duplicate note identifiers.")
            }
            return sorted(envelope.notes)
        } catch let error as NoteStoreError {
            throw error
        } catch {
            throw NoteStoreError.invalidFile(error.localizedDescription)
        }
    }

    private func persist(_ next: [StickNote]) throws {
        // Recheck before writing in case another version or external editor has
        // replaced the file since launch. Never overwrite unreadable data.
        _ = try Self.load(fileURL)
        let ordered = Self.sorted(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(version: 1, notes: ordered))
        try data.write(to: fileURL, options: .atomic)
        notes = ordered
    }
}
