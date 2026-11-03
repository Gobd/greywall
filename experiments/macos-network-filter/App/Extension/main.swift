import FilterPrototype
import Foundation
import NetworkExtension

// Keep the provider linked into the system-extension executable.
_ = FilterDataProvider.self
NEProvider.startSystemExtensionMode()
guard let settings = Bundle.main.infoDictionary?["NetworkExtension"] as? [String: Any],
      let service = settings["NEMachServiceName"] as? String else {
    fatalError("Missing explicit provider control service")
}
let listener = NSXPCListener(machServiceName: service)
listener.delegate = FilterControlListener.shared
listener.resume()
dispatchMain()
