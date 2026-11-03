import Foundation
import ProcessInfoShim

public struct ProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64

    public init(pid: Int32, parentPID: Int32, startSeconds: UInt64, startMicroseconds: UInt64 = 0) {
        self.pid = pid
        self.parentPID = parentPID
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }

    public func sameProcess(as other: ProcessIdentity) -> Bool {
        pid == other.pid && startSeconds == other.startSeconds && startMicroseconds == other.startMicroseconds
    }

    public static func lookup(_ pid: Int32) -> ProcessIdentity? {
        var info = gw_process_info()
        guard gw_process_lookup(pid, &info) == 1 else { return nil }
        return ProcessIdentity(pid: info.pid, parentPID: info.parent_pid,
                               startSeconds: info.start_seconds, startMicroseconds: info.start_microseconds)
    }
}

public enum Scope: String { case tracked, unrelated, unknown }

// Deliberately NOT a production process tracker. A live ancestry walk can miss
// children that have already been reparented. No global executable-name matching.
public struct ProcessScope {
    public let root: ProcessIdentity
    public init(root: ProcessIdentity) { self.root = root }

    public func classify(_ pid: Int32, lookup: (Int32) -> ProcessIdentity? = ProcessIdentity.lookup) -> Scope {
        guard let currentRoot = lookup(root.pid), currentRoot.sameProcess(as: root) else { return .unknown }
        var next = pid
        var visited = Set<Int32>()
        for _ in 0..<128 {
            guard next > 0, visited.insert(next).inserted, let process = lookup(next) else { return .unknown }
            if next == root.pid { return process.sameProcess(as: root) ? .tracked : .unknown }
            // An older process cannot be a descendant. Also avoids walking into
            // unrelated, privileged ancestors whose metadata is inaccessible.
            if process.startSeconds < root.startSeconds ||
               (process.startSeconds == root.startSeconds && process.startMicroseconds < root.startMicroseconds) {
                return .unrelated
            }
            if process.parentPID <= 1 { return .unrelated }
            next = process.parentPID
        }
        return .unknown
    }
}

public struct Destination: Codable, Hashable {
    public enum Transport: String, Codable { case tcp, udp }
    public let address: String
    public let port: UInt16
    public let transport: Transport

    public init(address: String, port: UInt16, transport: Transport) {
        self.address = address
        self.port = port
        self.transport = transport
    }
}

public struct SessionConfiguration: Codable {
    public enum Mode: String, Codable { case learn, enforce }
    public let root: ProcessIdentity
    public let mode: Mode
    public let allowed: Set<Destination>

    public init(root: ProcessIdentity, mode: Mode, allowed: Set<Destination> = []) {
        self.root = root
        self.mode = mode
        self.allowed = allowed
    }
}

public struct CandidatePolicy: Codable {
    public let schemaVersion: Int
    public let destinations: [Destination]
    public init(destinations: Set<Destination>) {
        schemaVersion = 1
        self.destinations = destinations.sorted {
            ($0.address, $0.port, $0.transport.rawValue) < ($1.address, $1.port, $1.transport.rawValue)
        }
    }
}

public enum Decision: String { case allow, drop, unattributed }

// Serialized by the caller; no payload inspection, DNS guesses or wildcard grants.
public struct PolicyEngine {
    public let configuration: SessionConfiguration
    public private(set) var observed = Set<Destination>()

    public init(configuration: SessionConfiguration) { self.configuration = configuration }

    public mutating func decide(scope: Scope, destination: Destination?) -> Decision {
        switch scope {
        case .unrelated: return .allow
        case .unknown: return .unattributed
        case .tracked:
            guard let destination else { return .drop }
            if configuration.mode == .learn {
                observed.insert(destination)
                return .allow
            }
            return configuration.allowed.contains(destination) ? .allow : .drop
        }
    }

    public func candidateJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(CandidatePolicy(destinations: observed))
    }
}
