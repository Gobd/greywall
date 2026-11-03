import FilterPrototype
import Foundation
import NetworkExtension

// Keep the provider linked into the system-extension executable.
_ = FilterDataProvider.self
NEProvider.startSystemExtensionMode()
dispatchMain()
