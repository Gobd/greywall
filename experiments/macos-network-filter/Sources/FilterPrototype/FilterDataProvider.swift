import Foundation
import Network
import NetworkExtension
import NetworkPolicy
import OSLog
import ProcessInfoShim

// Experimental provider; activation is only through explicit host-app actions.
// Unknown attribution is explicitly NOT a security boundary: leave host traffic
// alone and report the gap. Production needs a trusted lifecycle-aware tracker.
@objc(GreywallFilterDataProvider)
public final class FilterDataProvider: NEFilterDataProvider {
    private let lock = NSLock()
    private var engine: PolicyEngine?
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
            lock.unlock()

            // Loopback is otherwise exempt from the default filter action.
            let loopback: [(String, Int)] = [("127.0.0.1", 8), ("::1", 128)]
            let rules = loopback.map { address, prefix in
                NEFilterRule(networkRule: NENetworkRule(
                    remoteNetworkEndpoint: .hostPort(host: .init(address), port: .init(rawValue: 0)!), remotePrefix: prefix,
                    localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .outbound),
                    action: .filterData)
            }
            apply(NEFilterSettings(rules: rules, defaultAction: .filterData)) { error in
                if let error { self.log.error("Provider settings failed: \(String(describing: error), privacy: .public)") }
                else { self.log.notice("Provider settings applied; mode=\(configuration.mode.rawValue, privacy: .public) root=\(configuration.root.pid)") }
                completionHandler(error)
            }
        } catch {
            completionHandler(error)
        }
    }

    public override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Inbound server traffic is out of scope for this outbound experiment.
        guard flow.direction == .outbound else { return .allow() }
        lock.lock()
        defer { lock.unlock() }
        guard var policy = engine else {
            log.error("No session policy: prototype cannot attribute flow")
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
        log.notice("scope=\(scope.rawValue, privacy: .public) decision=\(decision.rawValue, privacy: .public) destination=\(String(describing: destination), privacy: .public)")
        // A missing endpoint for a tracked flow is dropped, not silently allowed.
        // In a fuller implementation, defer to the data callback when it becomes available.
        return decision == .drop ? .drop() : .allow()
    }

    private func classify(_ flow: NEFilterFlow, tracker: ProcessScope) -> Scope {
        // App attribution can differ for system-mediated connections; inspect both.
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
