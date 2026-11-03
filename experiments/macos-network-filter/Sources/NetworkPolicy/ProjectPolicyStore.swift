import Foundation

public enum ProjectPolicyStore {
    public static func load(from file: URL) throws -> Set<Destination> {
        try checkLocation(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 2 * 1024 * 1024 else {
            throw failure("Policy must be a regular JSON file smaller than 2 MiB")
        }
        let candidate = try JSONDecoder().decode(CandidatePolicy.self, from: Data(contentsOf: file))
        guard candidate.schemaVersion == 1 else { throw failure("Unsupported project network policy schema") }
        for destination in candidate.destinations {
            guard !destination.address.isEmpty, !destination.address.contains("*"),
                  destination.address == destination.address.trimmingCharacters(in: .whitespacesAndNewlines),
                  destination.port > 0 else { throw failure("Only exact addresses and nonzero ports may be granted") }
        }
        return Set(candidate.destinations)
    }

    public static func save(_ destinations: Set<Destination>, to file: URL) throws {
        try checkLocation(file)
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(CandidatePolicy(destinations: destinations)).write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func checkLocation(_ file: URL) throws {
        let manager = FileManager.default
        for location in [file.deletingLastPathComponent(), file] {
            if let attributes = try? manager.attributesOfItem(atPath: location.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw failure("Refusing a symlinked policy location")
            }
        }
    }
    private static func failure(_ text: String) -> Error {
        NSError(domain: "GreywallProjectPolicy", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
