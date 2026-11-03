import XCTest
import Foundation
@testable import NetworkPolicy
@testable import NativeControl

final class ProjectAndReadinessTests: XCTestCase {
    let root = ProcessIdentity(pid: 100, parentPID: 1, startSeconds: 10)
    let destination = Destination(address: "127.0.0.1", port: 1234, transport: .tcp)

    func testPolicyRoundTripAndMissingDenies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".greywall/network.json")
        XCTAssertEqual(try ProjectPolicyStore.load(from: file), [])
        try ProjectPolicyStore.save([destination], to: file)
        XCTAssertEqual(try ProjectPolicyStore.load(from: file), [destination])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testPolicyRejectsWildcardAndUnknownVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("network.json")
        for text in [#"{"schemaVersion":2,"destinations":[]}"#, #"{"schemaVersion":1,"destinations":[{"address":"*","port":443,"transport":"tcp"}]}"#] {
            try Data(text.utf8).write(to: file)
            XCTAssertThrowsError(try ProjectPolicyStore.load(from: file))
        }
    }
    func testPolicyRejectsSymlinkDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent(".greywall")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try ProjectPolicyStore.save([destination], to: link.appendingPathComponent("network.json")))
    }
    func testNotReadySuccessTimesOut() {
        let start = Date(timeIntervalSince1970: 100)
        var monitor = ReadinessMonitor(root: root, mode: .learn, now: start)
        let snapshot = FilterSnapshot(ready: false, configuration: .init(root: root, mode: .learn), observed: [], allowedFlows: 0, droppedFlows: 0)
        XCTAssertEqual(monitor.observe(snapshot, now: start), .starting)
        XCTAssertEqual(monitor.observe(snapshot, now: start.addingTimeInterval(15)), .failed)
    }
    func testWrongGenerationOrModeNotReady() {
        let start = Date(timeIntervalSince1970: 100)
        var monitor = ReadinessMonitor(root: root, mode: .enforce, now: start)
        let replacement = ProcessIdentity(pid: root.pid, parentPID: 1, startSeconds: 999)
        let snapshot = FilterSnapshot(ready: true, configuration: .init(root: replacement, mode: .enforce), observed: [], allowedFlows: 1, droppedFlows: 0)
        XCTAssertEqual(monitor.observe(snapshot, now: start.addingTimeInterval(16)), .failed)
        var other = ReadinessMonitor(root: root, mode: .enforce, now: start)
        let wrongMode = FilterSnapshot(ready: true, configuration: .init(root: root, mode: .learn), observed: [], allowedFlows: 1, droppedFlows: 0)
        XCTAssertEqual(other.observe(wrongMode, now: start.addingTimeInterval(16)), .failed)
    }
    func testReadyThenProviderLossFails() {
        let start = Date(timeIntervalSince1970: 100)
        var monitor = ReadinessMonitor(root: root, mode: .learn, now: start)
        let snapshot = FilterSnapshot(ready: true, configuration: .init(root: root, mode: .learn), observed: [destination], allowedFlows: 1, droppedFlows: 0)
        XCTAssertEqual(monitor.observe(snapshot, now: start), .ready)
        XCTAssertEqual(monitor.observe(nil, now: start.addingTimeInterval(4)), .starting)
        XCTAssertEqual(monitor.observe(nil, now: start.addingTimeInterval(5)), .failed)
    }
}
