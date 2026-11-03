import Foundation
import NativeControl
import NetworkPolicy
import ProcessInfoShim

// Only the live, generation-matched root of the active session can read its
// snapshot. Descendants cannot change rules or grant themselves permissions.
public final class FilterControlListener: NSObject, NSXPCListenerDelegate {
    public static let shared = FilterControlListener()
    private let lock = NSLock()
    private weak var provider: FilterDataProvider?

    public func register(_ provider: FilterDataProvider) {
        lock.lock(); defer { lock.unlock() }
        self.provider = provider
    }
    public func authorizedSnapshot(pid: Int32, uid: uid_t) -> FilterSnapshot? {
        lock.lock()
        let current = provider
        lock.unlock()
        guard let snapshot = current?.currentSnapshot(),
              snapshot.configuration.root.pid == pid,
              let identity = ProcessIdentity.lookup(pid),
              identity.sameProcess(as: snapshot.configuration.root),
              gw_process_uid(pid) == Int64(uid) else { return nil }
        return snapshot
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard authorizedSnapshot(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier) != nil else { return false }
        connection.exportedInterface = NSXPCInterface(with: NativeFilterControl.self)
        connection.exportedObject = SnapshotService(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier)
        connection.resume()
        return true
    }
}

private final class SnapshotService: NSObject, NativeFilterControl {
    let pid: Int32
    let uid: uid_t
    init(pid: Int32, uid: uid_t) { self.pid = pid; self.uid = uid }
    func snapshot(_ reply: @escaping (Data?, String?) -> Void) {
        guard let snapshot = FilterControlListener.shared.authorizedSnapshot(pid: pid, uid: uid) else {
            reply(nil, "Only the active session root can read provider state")
            return
        }
        do { reply(try JSONEncoder().encode(snapshot), nil) }
        catch { reply(nil, String(describing: error)) }
    }
}
