import Foundation
import Network
import NetworkExtension
import NetworkPolicy
import NativeControl
import OSLog
import ProcessInfoShim

// Experimental provider; activation is only through explicit host-app actions.
// Unknown attribution is explicitly NOT a security boundary: leave host traffic
// alone and report the gap. Production needs a trusted lifecycle-aware tracker.
@objc(GreywallFilterDataProvider)
public final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var engine: PolicyEngine?
    private var ready = false
    private var allowedFlows = 0
    private var droppedFlows = 0
    private var warnedDelegated = false
    private let log = Logger(subsystem: "io.greywall.network-experiment", category: "flows")

    public override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let data = filterConfiguration.vendorConfiguration?["sessionJSON"] as? Data else {
                throw NSError(domain: "GreywallExperiment", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Missing explicit session configuration"])
            }
            let configuration = try JSONDecoder().decode(SessionConfiguration.self, from: data)
            guard configuration.root.pid > 1,
                  let current = ProcessIdentity.lookup(configuration.root.pid),
                  current.sameProcess(as: configuration.root) else {
                throw NSError(domain: "GreywallExperiment", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Root process absent, changed, or unreadable"])
            }
            lock.lock()
            engine = PolicyEngine(configuration: configuration)
            ready = false
            allowedFlows = 0
            droppedFlows = 0
            warnedDelegated = false
            lock.unlock()
            FilterControlListener.shared.register(self)

            // Loopback is otherwise exempt from the default filter action.
            let loopback: [(String, Int)] = [("127.0.0.1", 8), ("::1", 128)]
            var rules = loopback.map { address, prefix in
                NEFilterRule(networkRule: NENetworkRule(
                    remoteNetworkEndpoint: .hostPort(host: .init(address), port: .init(rawValue: 0)!), remotePrefix: prefix,
                    localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound),
                    action: .filterData)
            }
            rules.append(NEFilterRule(networkRule: NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound), action: .filterData))
            // Do not put inbound host traffic through callbacks unnecessarily.
            apply(NEFilterSettings(rules: rules, defaultAction: .allow)) { error in
                self.lock.lock()
                self.ready = error == nil
                self.lock.unlock()
                if let error { self.log.error("Provider settings failed: \(String(describing: error), privacy: .public)") }
                else { self.log.notice("Provider settings applied; mode=\(configuration.mode.rawValue, privacy: .public) root=\(configuration.root.pid)") }
                completionHandler(error)
            }
        } catch {
            log.error("Provider startup failed: \(String(describing: error), privacy: .public)")
            completionHandler(error)
        }
    }

    public func currentSnapshot() -> FilterSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let engine else { return nil }
        return FilterSnapshot(ready: ready, configuration: engine.configuration, observed: engine.observed,
                              allowedFlows: allowedFlows, droppedFlows: droppedFlows)
    }

    public override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lock.lock()
        ready = false
        engine = nil
        lock.unlock()
        completionHandler()
    }

    public override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Inbound server traffic is out of scope for this outbound experiment.
        guard flow.direction == .outbound else { return .allow() }
        lock.lock()
        defer { lock.unlock() }
        guard var policy = engine else { return .allow() }
        guard let liveRoot = ProcessIdentity.lookup(policy.configuration.root.pid),
              liveRoot.sameProcess(as: policy.configuration.root) else {
            ready = false
            engine = nil
            log.notice("Session root gone/unreadable; removing callback rules, leaving host traffic alone")
            let pass = NEFilterRule(networkRule: NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .any), action: .allow)
            apply(NEFilterSettings(rules: [pass], defaultAction: .allow)) { _ in }
            return .allow()
        }
        let tracker = ProcessScope(root: policy.configuration.root)
        let scope = classify(flow, tracker: tracker)
        if scope == .unrelated { return .allow() }
        if scope == .unknown {
            log.error("Unattributed outbound flow; prototype left it unchanged. No destination recorded.")
            return .allow()
        }
        let destination = destination(flow)
        let decision = policy.decide(scope: scope, destination: destination)
        engine = policy
        if decision == .drop { droppedFlows += 1 } else { allowedFlows += 1 }
        log.notice("scope=\(scope.rawValue, privacy: .public) decision=\(decision.rawValue, privacy: .public) destination=\(String(describing: destination), privacy: .public)")
        // A missing endpoint for a tracked flow is dropped, not silently allowed.
        // In a fuller implementation, defer to the data callback when it becomes available.
        return decision == .drop ? .drop() : .allow()
    }

    private func classify(_ flow: NEFilterFlow, tracker: ProcessScope) -> Scope {
        // A shared resolver/proxy socket must not be dropped based only on an
        // app-attribution token. Direct child egress is additionally restricted
        // by inherited Seatbelt rules in the CLI; shared DNS is not a content policy.
        if let app = flow.sourceAppAuditToken, let process = flow.sourceProcessAuditToken, app != process {
            let pid = process.withUnsafeBytes { gw_audit_pid($0.baseAddress, $0.count) }
            if pid > 0 && tracker.classify(pid) != .tracked {
                if !warnedDelegated {
                    warnedDelegated = true
                    log.notice("Shared/system-mediated flow left untouched; native policy covers direct TCP/UDP, not DNS query content")
                }
                return .unrelated
            }
        }
        let scopes = [flow.sourceAppAuditToken, flow.sourceProcessAuditToken].compactMap { data -> Scope? in
            guard let data else { return nil }
            let pid = data.withUnsafeBytes { gw_audit_pid($0.baseAddress, $0.count) }
            guard pid > 0 else { return .unknown }
            return tracker.classify(pid)
        }
        if scopes.contains(.tracked) { return .tracked }
        if scopes.isEmpty || scopes.contains(.unknown) { return .unknown }
        return .unrelated
    }

    private func destination(_ flow: NEFilterFlow) -> Destination? {
        guard let socket = flow as? NEFilterSocketFlow,
              let endpoint = socket.remoteFlowEndpoint,
              case let .hostPort(host, port) = endpoint else { return nil }
        let transport: Destination.Transport
        switch socket.socketProtocol {
        case IPPROTO_TCP: transport = .tcp
        case IPPROTO_UDP: transport = .udp
        default: return nil
        }
        guard port.rawValue > 0 else { return nil }
        // Raw sockets usually expose IPs, not DNS names. Preserve what the OS reports.
        return Destination(address: String(describing: host), port: port.rawValue, transport: transport)
    }
}
