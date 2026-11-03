import AppKit
import NetworkExtension
import NetworkPolicy
import SystemExtensions

// No activation or network-settings writes occur on launch. Each is a button action.
final class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private var window: NSWindow!
    private let output = NSTextView()
    private let experimentPath = NSTextField(string: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
    private var request: OSSystemExtensionRequest?
    private var fixture: Process?
    private var filterEnabledByThisApp = false
    private var extensionReady = false
    private var activationRequested = false
    private var extensionID: String { (Bundle.main.bundleIdentifier ?? "dev.greywall.NetworkExperiment") + ".filter" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menuItem = NSMenuItem()
        menuItem.submenu = appMenu
        menu.addItem(menuItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Greywall Native Network Experiment — NOT a production sandbox"
        window.isReleasedWhenClosed = false
        let title = NSTextField(wrappingLabelWithString: "Nothing is installed or enabled automatically. The buttons below change ONLY this experiment's extension/filter. Unknown process attribution remains a containment gap.")
        let buttons = NSStackView(views: [
            button("1. Activate extension", #selector(activate)),
            button("2. Enable learning", #selector(learn)),
            button("2. Enable drop-all", #selector(enforce)),
        ])
        buttons.orientation = .horizontal
        let controls = NSStackView(views: [
            button("Run local baseline", #selector(runFixture)),
            button("Disable filter", #selector(disable)),
            button("Deactivate extension", #selector(deactivate)),
        ])
        controls.orientation = .horizontal
        let folder = NSStackView(views: [NSTextField(labelWithString: "Experiment source folder:"), experimentPath,
                                         button("Choose…", #selector(chooseFolder))])
        folder.orientation = .horizontal
        experimentPath.widthAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        experimentPath.isEditable = true
        experimentPath.isSelectable = true
        experimentPath.placeholderString = "Paste a folder path or choose one…"
        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.textColor = .textColor
        output.backgroundColor = .textBackgroundColor
        let scroll = NSScrollView()
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.documentView = output
        let stack = NSStackView(views: [title, buttons, folder, controls, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 270),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        append("App PID \(getpid()). No filter enabled by launch.\nFlow diagnostics: /usr/bin/log stream --style compact --predicate 'subsystem == \"io.greywall.network-experiment\"'\n")
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }
    private func append(_ text: String) {
        DispatchQueue.main.async {
            self.output.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [
                .foregroundColor: NSColor.textColor,
                .font: self.output.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ]))
            self.output.scrollToEndOfDocument(nil)
        }
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { experimentPath.stringValue = url.path }
    }
    @objc private func activate() {
        let operation = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main)
        operation.delegate = self
        request = operation
        activationRequested = true
        append("Requesting activation; macOS may require approval. No filter policy enabled yet.")
        OSSystemExtensionManager.shared.submitRequest(operation)
    }
    @objc private func learn() { configure(.learn) }
    @objc private func enforce() { configure(.enforce) }
    private func configure(_ mode: SessionConfiguration.Mode) {
        guard extensionReady else { append("Activate the extension first."); return }
        guard !filterEnabledByThisApp else { append("Disable the filter before enabling another mode."); return }
        guard fixture == nil else { append("Wait for the fixture to finish before changing policy."); return }
        guard let root = ProcessIdentity.lookup(getpid()) else { append("Cannot read root identity."); return }
        do {
            let data = try JSONEncoder().encode(SessionConfiguration(root: root, mode: mode))
            let manager = NEFilterManager.shared()
            manager.loadFromPreferences { error in
                if let error { self.append("Load failed: \(error)"); return }
                if let existing = manager.providerConfiguration?.filterDataProviderBundleIdentifier,
                   existing != self.extensionID {
                    self.append("Refusing to change a different provider: \(existing)"); return
                }
                let configuration = NEFilterProviderConfiguration()
                configuration.filterSockets = true
                configuration.filterPackets = false
                configuration.filterDataProviderBundleIdentifier = self.extensionID
                configuration.vendorConfiguration = ["sessionJSON": data]
                manager.providerConfiguration = configuration
                manager.localizedDescription = "Greywall Native Network Experiment"
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    if let error { self.append("Enable failed: \(error)"); return }
                    self.filterEnabledByThisApp = true
                    self.append("Saved \(mode.rawValue) settings for this app's descendants. This is NOT a provider readiness handshake. Confirm provider-start/flow logs before interpreting results. Drop-all has NO allowed destinations.")
                }
            }
        } catch { append("Configuration failed: \(error)") }
    }
    @objc private func disable() { disableFilter { _ in } }
    private func disableFilter(completion: @escaping (Bool) -> Void) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            if let error { self.append("Load failed: \(error)"); completion(false); return }
            guard manager.providerConfiguration?.filterDataProviderBundleIdentifier == self.extensionID else {
                self.append("No matching experiment configuration to disable."); completion(true); return
            }
            manager.isEnabled = false
            manager.saveToPreferences { error in
                if let error { self.append("Disable failed: \(error)"); completion(false); return }
                self.filterEnabledByThisApp = false
                self.append("Disabled ONLY this experiment's filter.")
                completion(true)
            }
        }
    }
    @objc private func deactivate() {
        disableFilter { success in
            guard success else { return }
            let operation = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: self.extensionID, queue: .main)
            operation.delegate = self
            self.request = operation
            self.extensionReady = false
            self.activationRequested = false
            OSSystemExtensionManager.shared.submitRequest(operation)
        }
    }
    @objc private func runFixture() {
        guard fixture == nil else { append("Fixture already running."); return }
        let entered = experimentPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (entered as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: folder).standardizedFileURL.appendingPathComponent("fixtures/baseline.py")
        guard FileManager.default.fileExists(atPath: path.path) else { append("Choose the experiment folder containing fixtures/baseline.py."); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [path.path]
        process.currentDirectoryURL = path.deletingLastPathComponent().deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.append(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                self.fixture = nil
                self.append("Fixture exit \(finished.terminationStatus). Correlate success/failure with the provider's tracked allow/drop logs before interpreting filtering behavior.")
            }
        }
        do { try process.run(); fixture = process }
        catch { pipe.fileHandleForReading.readabilityHandler = nil; append("Fixture launch failed: \(error)") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if fixture != nil { append("Wait for the local fixture to finish before quitting."); return .terminateCancel }
        guard filterEnabledByThisApp else { return .terminateNow }
        disableFilter { success in NSApp.reply(toApplicationShouldTerminate: success) }
        return .terminateLater
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        append("Approve Greywall in System Settings → General → Login Items & Extensions → Network Extensions.")
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        extensionReady = activationRequested && result == .completed && request.identifier == extensionID
        append("System extension request result: \(result.rawValue). If macOS requests a reboot, stop here; don't reboot just for this experiment without deciding to.")
        self.request = nil
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        append("System extension request failed: \(error)")
        self.request = nil
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Do not replace an existing version automatically.
        append("Existing extension found. Deactivate the old experiment before replacing it.")
        return .cancel
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
