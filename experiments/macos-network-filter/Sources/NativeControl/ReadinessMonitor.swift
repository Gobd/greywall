import Foundation
import NetworkPolicy

public struct ReadinessMonitor {
    public enum State: Equatable { case starting, ready, failed }
    private let root: ProcessIdentity
    private let mode: SessionConfiguration.Mode
    private let started: Date
    private var lastVerified: Date?

    public init(root: ProcessIdentity, mode: SessionConfiguration.Mode, now: Date = Date()) {
        self.root = root
        self.mode = mode
        self.started = now
    }
    public mutating func observe(_ snapshot: FilterSnapshot?, now: Date = Date()) -> State {
        if let snapshot, snapshot.ready, snapshot.configuration.root.sameProcess(as: root), snapshot.configuration.mode == mode {
            lastVerified = now
            return .ready
        }
        if let lastVerified { return now.timeIntervalSince(lastVerified) >= 5 ? .failed : .starting }
        return now.timeIntervalSince(started) >= 15 ? .failed : .starting
    }
}
