import Foundation
import NetworkExtension
import NetworkPolicy
import NativeControl
import SystemExtensions
import Darwin

// Explicit CLI opt-in only. Does NOT activate/install an extension. Go supplies
// the filesystem wrapper; IP egress enforcement is explicitly best-effort on
// macOS. Readiness is established before spawning the workload.
final class NativeLaunch: NSObject, OSSystemExtensionRequestDelegate {
    private var lease: NativeSessionLease?
    private var request: OSSystemExtensionRequest?
    private var root: ProcessIdentity!
    private var mode: SessionConfiguration.Mode = .enforce
    private var policy: URL!
    private var export: URL?
    private var directory: URL!
    private var command: [String] = []
    private var child: Process?
    private var heartbeat: Timer?
    private var readyDeadline = Date()
    private var service = ""
    private var failures = 0
    private var heartbeatInFlight = false
    private var failureStatus: Int32?
    private var ownedGroup: Int32?
    private var settingsOwned = false
    private var finishing = false
    private var signalSources: [DispatchSourceSignal] = []
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "") + ".filter" }

    func start(arguments: [String]) {
        do {
            var index = 0
            var fields: [String: String] = [:]
            while index < arguments.count && arguments[index] != "--" {
                guard index + 1 < arguments.count, ["--mode", "--policy", "--export", "--cwd"].contains(arguments[index]), fields[arguments[index]] == nil else {
                    throw error("Invalid native launcher options")
                }
                fields[arguments[index]] = arguments[index + 1]
                index += 2
            }
            guard index < arguments.count, let policyPath = fields["--policy"], let cwd = fields["--cwd"],
                  let modeText = fields["--mode"], let selected = SessionConfiguration.Mode(rawValue: modeText),
                  let identity = ProcessIdentity.lookup(getpid()) else { throw error("Missing explicit native session options") }
            command = Array(arguments.dropFirst(index + 1))
            guard !command.isEmpty else { throw error("No native command supplied") }
            policy = URL(fileURLWithPath: policyPath)
            directory = URL(fileURLWithPath: cwd)
            export = fields["--export"].map { URL(fileURLWithPath: $0) }
            mode = selected
            root = identity
            service = try FilterClient.serviceName()
            lease = try NativeSessionLease()
            // Properties requests are read-only; never substitute an activation request.
            let operation = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main)
            operation.delegate = self
            request = operation
            OSSystemExtensionManager.shared.submitRequest(operation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                if self.child == nil && !self.finishing { self.finish(status: 70, message: "Native startup timed out; no command launched") }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                if self.request != nil { self.finish(status: 70, message: "Extension status request timed out; command not started") }
            }
        } catch { finish(status: 70, message: String(describing: error)) }
    }

    private func configure() {
        do {
            let allowed = try ProjectPolicyStore.load(from: policy)
            let manager = NEFilterManager.shared()
            manager.loadFromPreferences { error in
                if let error { self.finish(status: 70, message: "Cannot load native settings: \(error)"); return }
                guard !manager.isEnabled else {
                    self.finish(status: 70, message: "A native filter is already enabled. Disable the previous GUI/session first."); return
                }
                do {
                    let configuration = NEFilterProviderConfiguration()
                    configuration.filterSockets = true
                    configuration.filterPackets = false
                    configuration.filterDataProviderBundleIdentifier = self.identifier
                    configuration.vendorConfiguration = ["sessionJSON": try JSONEncoder().encode(SessionConfiguration(root: self.root, mode: self.mode, allowed: allowed))]
                    manager.providerConfiguration = configuration
                    manager.localizedDescription = "Greywall native project session"
                    manager.isEnabled = true
                    manager.saveToPreferences { error in
                        if let error { self.finish(status: 70, message: "Cannot enable native settings: \(error)"); return }
                        self.settingsOwned = true
                        self.readyDeadline = Date().addingTimeInterval(15)
                        self.pollReadiness()
                    }
                } catch { self.finish(status: 70, message: String(describing: error)) }
            }
        } catch { finish(status: 70, message: String(describing: error)) }
    }
    private func matching(_ snapshot: FilterSnapshot) -> Bool {
        snapshot.ready && snapshot.configuration.root.sameProcess(as: root) && snapshot.configuration.mode == mode
    }
    private func pollReadiness() {
        guard !finishing else { return }
        FilterClient(serviceName: service).snapshot { result in
            if case let .success(snapshot) = result, self.matching(snapshot) { self.launch(); return }
            if Date() > self.readyDeadline { self.finish(status: 70, message: "Provider readiness not established; command not started"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.pollReadiness() }
        }
    }
    private func launch() {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            for key in Array(environment.keys) where ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains(key.lowercased()) {
                environment.removeValue(forKey: key)
            }
            process.environment = environment
            process.standardInput = FileHandle.standardInput
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            process.terminationHandler = { completed in DispatchQueue.main.async { self.completed(status: completed.terminationStatus) } }
            child = process
            try process.run()
            if getpgid(process.processIdentifier) == process.processIdentifier { ownedGroup = process.processIdentifier }
            for number in [SIGINT, SIGTERM, SIGHUP, SIGWINCH] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { if self.child?.isRunning == true { self.signalChild(number) } }
                source.resume()
                signalSources.append(source)
            }
            write("Provider ready. Started project command; native direct egress remains experimental.\n")
            heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                guard !self.heartbeatInFlight, !self.finishing else { return }
                self.heartbeatInFlight = true
                FilterClient(serviceName: self.service).snapshot { result in
                    self.heartbeatInFlight = false
                    guard !self.finishing else { return }
                    if case let .success(snapshot) = result, self.matching(snapshot) { self.failures = 0; return }
                    self.failures += 1
                    if self.failures >= 3 {
                        self.heartbeat?.invalidate()
                        self.failureStatus = 70
                        self.write("Provider readiness lost; terminating owned command, no policy export.\n")
                        self.signalChild(SIGTERM)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            if self.child?.isRunning == true { self.signalChild(SIGKILL) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if !self.finishing { self.finish(status: 70, message: "Command shutdown deadline exceeded") }
                        }
                    }
                }
            }
        } catch { finish(status: 70, message: "Command launch failed: \(error)") }
    }
    private func signalChild(_ number: Int32) {
        guard let child, child.isRunning else { return }
        if let group = ownedGroup, getpgid(child.processIdentifier) == group { kill(-group, number) }
        else { kill(child.processIdentifier, number) }
    }
    private func completed(status: Int32) {
        guard !finishing else { return }
        heartbeat?.invalidate()
        if let failureStatus { finish(status: failureStatus); return }
        if status != 0 || mode != .learn { finish(status: status); return }
        FilterClient(serviceName: service).snapshot { result in
            do {
                guard case let .success(snapshot) = result, self.matching(snapshot), let output = self.export else {
                    throw self.error("No verified final learning snapshot; previous policy retained")
                }
                try ProjectPolicyStore.save(snapshot.observed.union(snapshot.configuration.allowed), to: output)
                self.write("Captured \(snapshot.observed.count) destinations; candidate exported for Greywall to commit.\n")
                self.finish(status: 0)
            } catch { self.finish(status: 70, message: String(describing: error)) }
        }
    }
    private func finish(status: Int32, message: String? = nil) {
        guard !finishing else { return }
        finishing = true
        heartbeat?.invalidate()
        if let message { write(message + "\n") }
        guard settingsOwned else { lease = nil; exit(status) }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            guard error == nil, manager.providerConfiguration?.filterDataProviderBundleIdentifier == self.identifier,
                  let data = manager.providerConfiguration?.vendorConfiguration?["sessionJSON"] as? Data,
                  let configuration = try? JSONDecoder().decode(SessionConfiguration.self, from: data),
                  configuration.root.sameProcess(as: self.root) else {
                self.write("Could not verify ownership for cleanup; no unrelated configuration modified.\n")
                exit(70)
            }
            manager.isEnabled = false
            manager.saveToPreferences { error in
                if let error { self.write("Filter cleanup failed: \(error)\n"); exit(70) }
                self.lease = nil
                exit(status)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.write("Cleanup timed out; check this experiment's filter in the app.\n"); exit(70) }
    }
    private func write(_ text: String) { FileHandle.standardError.write(Data(("[greywall:native] " + text).utf8)) }
    private func error(_ text: String) -> Error { NSError(domain: "GreywallNativeLaunch", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        self.request = nil
        guard properties.contains(where: { $0.bundleIdentifier == identifier && $0.isEnabled && !$0.isUninstalling && Int($0.bundleVersion) ?? 0 >= 2 }) else {
            finish(status: 70, message: "Updated native extension is not enabled. Install/approve it explicitly in the app; no automatic activation."); return
        }
        configure()
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { finish(status: 70, message: "Approve the extension in the app first") }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { self.request = nil; finish(status: 70, message: String(describing: error)) }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {}
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .cancel }
}
