import Foundation
import NetworkExtension
import NetworkPolicy
import Darwin

func emit<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func ancestryProbe() throws {
    guard let root = ProcessIdentity.lookup(getpid()) else { throw ProbeError.message("Cannot read own process identity") }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("grandchild.pid")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 20 & kid=$!; echo $kid > \"$1\"; wait $kid", "probe", pidFile.path]
    try child.run()
    defer {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = kill(pid, SIGTERM)
        }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
    }
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: pidFile.path) && Date() < deadline { usleep(10_000) }
    let text = try String(contentsOf: pidFile, encoding: .utf8)
    guard let grandchild = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ProbeError.message("Invalid grandchild PID")
    }
    let tracker = ProcessScope(root: root)
    let results = [
        "root": tracker.classify(root.pid),
        "child": tracker.classify(child.processIdentifier),
        "grandchild": tracker.classify(grandchild),
        "calling_terminal_or_agent": tracker.classify(getppid()),
    ]
    for (name, scope) in results.sorted(by: { $0.key < $1.key }) { print("\(name): \(scope.rawValue)") }
    guard results["root"] == .tracked, results["child"] == .tracked,
          results["grandchild"] == .tracked, results["calling_terminal_or_agent"] == .unrelated else {
        throw ProbeError.message("Ancestry probe failed; no containment established")
    }
    print("PASS: live process ancestry only; no network interception tested.")
}

enum ProbeError: Error { case message(String) }
let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "ancestry": try ancestryProbe()
    case "identity":
        guard args.count == 2, let pid = Int32(args[1]), let identity = ProcessIdentity.lookup(pid) else {
            throw ProbeError.message("Usage: network-probe identity PID")
        }
        try emit(identity)
    case "preflight":
        // Read only. No saveToPreferences, OSSystemExtensionRequest or network changes.
        print("Reading caller's filter preferences; this does NOT activate a filter.")
        NEFilterManager.shared().loadFromPreferences { error in
            if let error = error as NSError? {
                print("NetworkExtension read failed: \(error.domain) code=\(error.code): \(error.localizedDescription)")
                print("A signed, entitled app is required for live extension testing.")
                exit(2)
            }
            print("Preferences read succeeded. This does NOT prove extension activation or interception.")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            print("Preferences read timed out. No settings were changed.")
            exit(2)
        }
        dispatchMain()
    default:
        print("Usage: network-probe ancestry | identity PID | preflight")
        exit(1)
    }
} catch {
    fputs("Probe failed: \(error)\n", stderr)
    exit(1)
}
