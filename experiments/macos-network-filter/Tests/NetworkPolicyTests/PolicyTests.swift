import XCTest
@testable import NetworkPolicy

final class PolicyTests: XCTestCase {
    let root = ProcessIdentity(pid: 100, parentPID: 50, startSeconds: 10)
    let tcp = Destination(address: "127.0.0.1", port: 18080, transport: .tcp)
    let udp = Destination(address: "127.0.0.1", port: 18080, transport: .udp)

    func testDescendantsAndUnrelatedProcess() {
        let tree: [Int32: ProcessIdentity] = [
            100: root,
            101: .init(pid: 101, parentPID: 100, startSeconds: 11),
            102: .init(pid: 102, parentPID: 101, startSeconds: 12),
            50: .init(pid: 50, parentPID: 1, startSeconds: 1),
            200: .init(pid: 200, parentPID: 50, startSeconds: 12),
        ]
        let scope = ProcessScope(root: root)
        XCTAssertEqual(scope.classify(100, lookup: { tree[$0] }), .tracked)
        XCTAssertEqual(scope.classify(102, lookup: { tree[$0] }), .tracked)
        XCTAssertEqual(scope.classify(200, lookup: { tree[$0] }), .unrelated)
        XCTAssertEqual(scope.classify(999, lookup: { tree[$0] }), .unknown)
    }

    func testReusedRootPIDIsNotTrusted() {
        let replacement = ProcessIdentity(pid: root.pid, parentPID: 50, startSeconds: 999)
        XCTAssertEqual(ProcessScope(root: root).classify(root.pid, lookup: { _ in replacement }), .unknown)
    }

    func testCycleDoesNotHang() {
        XCTAssertEqual(ProcessScope(root: root).classify(101, lookup: { pid in
            pid == 100 ? self.root : .init(pid: pid, parentPID: pid, startSeconds: 11)
        }), .unknown)
    }

    func testLearningRecordsOnlyTrackedDestinations() throws {
        var policy = PolicyEngine(configuration: .init(root: root, mode: .learn))
        XCTAssertEqual(policy.decide(scope: .tracked, destination: tcp), .allow)
        XCTAssertEqual(policy.decide(scope: .tracked, destination: tcp), .allow)
        XCTAssertEqual(policy.decide(scope: .unrelated, destination: udp), .allow)
        XCTAssertEqual(policy.decide(scope: .unknown, destination: udp), .unattributed)
        XCTAssertEqual(policy.observed, [tcp])
        let candidate = try JSONDecoder().decode(CandidatePolicy.self, from: policy.candidateJSON())
        XCTAssertEqual(candidate.schemaVersion, 1)
        XCTAssertEqual(candidate.destinations, [tcp])
    }

    func testReviewAndReplayWithoutWildcards() throws {
        var learning = PolicyEngine(configuration: .init(root: root, mode: .learn))
        _ = learning.decide(scope: .tracked, destination: tcp)
        let candidate = try JSONDecoder().decode(CandidatePolicy.self, from: learning.candidateJSON())
        var enforced = PolicyEngine(configuration: .init(root: root, mode: .enforce,
                                                        allowed: Set(candidate.destinations)))
        XCTAssertEqual(enforced.decide(scope: .tracked, destination: tcp), .allow)
        XCTAssertEqual(enforced.decide(scope: .tracked, destination: udp), .drop)
        XCTAssertEqual(enforced.decide(scope: .tracked, destination: .init(address: "127.0.0.1", port: 18081, transport: .tcp)), .drop)
        XCTAssertEqual(enforced.decide(scope: .tracked, destination: .init(address: "::1", port: 18080, transport: .tcp)), .drop)
        XCTAssertEqual(enforced.decide(scope: .unrelated, destination: udp), .allow)
        XCTAssertTrue(enforced.observed.isEmpty)
    }

    func testUnknownEndpointCannotBecomeGrant() {
        var policy = PolicyEngine(configuration: .init(root: root, mode: .learn))
        XCTAssertEqual(policy.decide(scope: .tracked, destination: nil), .drop)
        XCTAssertTrue(policy.observed.isEmpty)
    }

    func testIPv6AndProtocolSpecificRules() {
        let v6 = Destination(address: "::1", port: 18080, transport: .tcp)
        var policy = PolicyEngine(configuration: .init(root: root, mode: .enforce, allowed: [v6, udp]))
        XCTAssertEqual(policy.decide(scope: .tracked, destination: v6), .allow)
        XCTAssertEqual(policy.decide(scope: .tracked, destination: udp), .allow)
        XCTAssertEqual(policy.decide(scope: .tracked, destination: tcp), .drop)
    }

    func testDeterministicExportAndSessionRoundTrip() throws {
        var first = PolicyEngine(configuration: .init(root: root, mode: .learn))
        var second = first
        for destination in [tcp, udp] { _ = first.decide(scope: .tracked, destination: destination) }
        for destination in [udp, tcp] { _ = second.decide(scope: .tracked, destination: destination) }
        XCTAssertEqual(try first.candidateJSON(), try second.candidateJSON())
        let configuration = SessionConfiguration(root: root, mode: .enforce, allowed: first.observed)
        let decoded = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(decoded.root, root)
        XCTAssertEqual(decoded.mode, .enforce)
        XCTAssertEqual(decoded.allowed, first.observed)
    }

    func testReparentingLimitationIsExplicit() {
        // This is a known containment gap, not a passing security property.
        let orphan = ProcessIdentity(pid: 101, parentPID: 1, startSeconds: 11)
        XCTAssertEqual(ProcessScope(root: root).classify(101, lookup: { pid in
            pid == 100 ? self.root : orphan
        }), .unrelated)
    }
}
