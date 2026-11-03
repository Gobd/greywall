import Foundation
import NetworkPolicy

@objc public protocol NativeFilterControl {
    // Read-only. No client may mutate permissions or approve its own requests.
    func snapshot(_ reply: @escaping (Data?, String?) -> Void)
}

public struct FilterSnapshot: Codable {
    public let ready: Bool
    public let configuration: SessionConfiguration
    public let observed: Set<Destination>
    public let allowedFlows: Int
    public let droppedFlows: Int
    public init(ready: Bool, configuration: SessionConfiguration, observed: Set<Destination>, allowedFlows: Int, droppedFlows: Int) {
        self.ready = ready
        self.configuration = configuration
        self.observed = observed
        self.allowedFlows = allowedFlows
        self.droppedFlows = droppedFlows
    }
}

public final class FilterClient {
    private let serviceName: String
    public init(serviceName: String) { self.serviceName = serviceName }

    public func snapshot(completion: @escaping (Result<FilterSnapshot, Error>) -> Void) {
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: NativeFilterControl.self)
        let lock = NSLock()
        var finished = false
        func finish(_ result: Result<FilterSnapshot, Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            connection.invalidationHandler = nil
            connection.invalidate()
            DispatchQueue.main.async { completion(result) }
        }
        connection.invalidationHandler = {
            finish(.failure(NSError(domain: "GreywallControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Provider snapshot channel unavailable; no readiness established"])))
        }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { finish(.failure($0)) } as? NativeFilterControl
        guard let proxy else {
            finish(.failure(NSError(domain: "GreywallControl", code: 2)))
            return
        }
        proxy.snapshot { data, message in
            guard let data else {
                finish(.failure(NSError(domain: "GreywallControl", code: 3, userInfo: [NSLocalizedDescriptionKey: message ?? "No provider snapshot"])))
                return
            }
            do { finish(.success(try JSONDecoder().decode(FilterSnapshot.self, from: data))) }
            catch { finish(.failure(error)) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            finish(.failure(NSError(domain: "GreywallControl", code: 4, userInfo: [NSLocalizedDescriptionKey: "Provider snapshot timed out"])))
        }
    }

    public static func serviceName(inApp app: Bundle = .main) throws -> String {
        guard let identifier = app.bundleIdentifier else { throw NSError(domain: "GreywallControl", code: 5) }
        let extensionURL = app.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/" + identifier + ".filter.systemextension")
        guard let extensionBundle = Bundle(url: extensionURL),
              let settings = extensionBundle.infoDictionary?["NetworkExtension"] as? [String: Any],
              let service = settings["NEMachServiceName"] as? String, !service.isEmpty else {
            throw NSError(domain: "GreywallControl", code: 6, userInfo: [NSLocalizedDescriptionKey: "This app/helper build does not provide the readiness channel"])
        }
        return service
    }
}
