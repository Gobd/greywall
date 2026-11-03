import AppKit
import NetworkExtension
import NetworkPolicy
import NativeControl
import SystemExtensions

// No activation or network-settings writes occur on launch. Each is a button action.
final class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private var window: NSWindow!
    private let output = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "Inactive — no filtering enabled by this app")
    private var snapshotTimer: Timer?
    private var lastSnapshot: FilterSnapshot?
    private var lease: NativeSessionLease?
    private var snapshotInFlight = false
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
            button("2. Enforce saved policy", #selector(enforceSaved)),
            button("Test drop-all", #selector(enforce)),
        ])
        buttons.orientation = .horizontal
        let controls = NSStackView(views: [
            button("Run local baseline", #selector(runFixture)),
            button("Disable filter", #selector(disable)),
            button("Deactivate extension", #selector(deactivate)),
        ])
        controls.orientation = .horizontal
        let logControls = NSStackView(views: [button("Copy Log", #selector(copyLog)), button("Save Learned Policy", #selector(saveLearnedPolicy))])
        logControls.orientation = .horizontal
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
        let stack = NSStackView(views: [title, status, buttons, folder, controls, logControls, scroll])
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
    @objc private func copyLog() {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        if !clipboard.setString(output.string, forType: .string) {
            append("Could not copy log to the clipboard.")
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
    private var policyURL: URL {
        let entered = experimentPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: (entered as NSString).expandingTildeInPath).standardizedFileURL
            .appendingPathComponent(".greywall/network.json")
    }
    @objc private func saveLearnedPolicy() {
        guard let snapshot = lastSnapshot, snapshot.ready, snapshot.configuration.mode == .learn else {
            append("No verified learning snapshot to save."); return
        }
        do {
            try ProjectPolicyStore.save(snapshot.observed, to: policyURL)
            append("Saved \(snapshot.observed.count) exact destinations to \(policyURL.path). Review before enforcement.")
        } catch { append("Policy save failed: \(error)") }
    }
    @objc private func enforceSaved() {
        do { configure(.enforce, allowed: try ProjectPolicyStore.load(from: policyURL)) }
        catch { append("Policy load failed: \(error)") }
    }
    @objc private func learn() { configure(.learn) }
    @objc private func enforce() { configure(.enforce) }
    private func configure(_ mode: SessionConfiguration.Mode, allowed: Set<Destination> = []) {
        guard extensionReady else { append("Activate the extension first."); return }
        guard !filterEnabledByThisApp else { append("Disable the filter before enabling another mode."); return }
        guard fixture == nil else { append("Wait for the fixture to finish before changing policy."); return }
        guard let root = ProcessIdentity.lookup(getpid()) else { append("Cannot read root identity."); return }
        do {
            _ = try FilterClient.serviceName() // reject an old app/helper build before changing settings
            lease = try NativeSessionLease()
            let data = try JSONEncoder().encode(SessionConfiguration(root: root, mode: mode, allowed: allowed))
            status.stringValue = "Starting — loading filter configuration…"
            let manager = NEFilterManager.shared()
            manager.loadFromPreferences { error in
                if let error { self.lease = nil; self.append("Load failed: \(error)"); return }
                if manager.isEnabled {
                    self.lease = nil
                    self.append("A filter is already enabled; disable the existing session first.")
                    return
                }
                if let existing = manager.providerConfiguration?.filterDataProviderBundleIdentifier,
                   existing != self.extensionID {
                    self.lease = nil
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
                    if let error { self.lease = nil; self.append("Enable failed: \(error)"); return }
                    DispatchQueue.main.async {
                        self.filterEnabledByThisApp = true
                        self.status.stringValue = "Starting — settings saved, waiting for provider readiness…"
                        self.append("Settings saved. Waiting for a generation-matched provider snapshot; not ready yet.")
                        self.startSnapshots(mode: mode)
                    }
                }
            }
        } catch { lease = nil; append("Configuration failed: \(error)") }
    }
    private func startSnapshots(mode: SessionConfiguration.Mode) {
        snapshotTimer?.invalidate()
        lastSnapshot = nil
        guard let root = ProcessIdentity.lookup(getpid()) else { disableFilter { _ in }; return }
        var monitor = ReadinessMonitor(root: root, mode: mode)
        func failed(_ message: String) {
            self.snapshotTimer?.invalidate()
            self.lastSnapshot = nil
            self.status.stringValue = "Failed — provider readiness lost/not established"
            self.append(message + ". Disabling only this session's filter.")
            self.disableFilter { _ in }
        }
        func refresh() {
            guard !self.snapshotInFlight else { return }
            self.snapshotInFlight = true
            do {
                FilterClient(serviceName: try FilterClient.serviceName()).snapshot { result in
                    self.snapshotInFlight = false
                    guard self.filterEnabledByThisApp else { return }
                    let snapshot: FilterSnapshot?
                    if case let .success(value) = result { snapshot = value } else { snapshot = nil }
                    switch monitor.observe(snapshot) {
                    case .ready:
                        guard let snapshot else { return }
                        let first = self.lastSnapshot == nil
                        self.lastSnapshot = snapshot
                        self.status.stringValue = "\(mode == .learn ? "Learning" : "Enforcing") — ready | allowed \(snapshot.allowedFlows) | dropped \(snapshot.droppedFlows) | learned \(snapshot.observed.count)"
                        if first { self.append("Provider READY for this process generation. Counters do not depend on OS log permissions.") }
                    case .starting:
                        self.lastSnapshot = nil
                        self.status.stringValue = "Starting/reconnecting — no verified readiness; fixture disabled"
                    case .failed:
                        failed("Readiness timeout or stale/wrong-mode provider snapshot")
                    }
                }
            } catch {
                self.snapshotInFlight = false
                failed("Snapshot setup failed: \(error)")
            }
        }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in refresh() }
        refresh()
    }
    @objc private func disable() { disableFilter { _ in } }
    private func disableFilter(completion: @escaping (Bool) -> Void) {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in
            if let error { self.append("Load failed: \(error)"); completion(false); return }
            guard manager.providerConfiguration?.filterDataProviderBundleIdentifier == self.extensionID else {
                self.lease = nil
                self.append("No matching experiment configuration to disable."); completion(true); return
            }
            if manager.isEnabled {
                guard let data = manager.providerConfiguration?.vendorConfiguration?["sessionJSON"] as? Data,
                      let configuration = try? JSONDecoder().decode(SessionConfiguration.self, from: data),
                      let current = ProcessIdentity.lookup(getpid()), current.sameProcess(as: configuration.root) else {
                    self.append("Refusing to disable a different session's filter. Use its owning launcher or System Settings.")
                    completion(false); return
                }
            }
            manager.isEnabled = false
            manager.saveToPreferences { error in
                if let error { self.append("Disable failed: \(error)"); completion(false); return }
                DispatchQueue.main.async {
                    self.filterEnabledByThisApp = false
                    self.snapshotTimer?.invalidate()
                    self.snapshotTimer = nil
                    self.lastSnapshot = nil
                    self.lease = nil
                    self.status.stringValue = "Inactive — filter configuration disabled"
                    self.append("Disabled ONLY this experiment's filter configuration.")
                    completion(true)
                }
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
        guard !filterEnabledByThisApp || lastSnapshot?.ready == true else {
            append("Provider is not ready; no fixture launched."); return
        }
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
        let alert = NSAlert()
        alert.messageText = "Replace the previous Greywall experiment?"
        alert.informativeText = "This updates only the Greywall helper from build \(existing.bundleVersion) to \(replacement.bundleVersion). Keep filtering disabled during the update."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace")
        return alert.runModal() == .alertSecondButtonReturn ? .replace : .cancel
    }
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--native-launch" {
    let launcher = NativeLaunch()
    launcher.start(arguments: Array(CommandLine.arguments.dropFirst(2)))
    withExtendedLifetime(launcher) { RunLoop.main.run() }
    exit(70)
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
