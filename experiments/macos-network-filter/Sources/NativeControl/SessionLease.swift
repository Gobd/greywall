import Foundation
import Darwin

// One native session at a time for now. This is user state, never a system-file
// edit. Keep it outside the sandbox's project grants and hold it until cleanup.
public final class NativeSessionLease {
    private var descriptor: Int32 = -1
    public init() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GreywallNative")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw NSError(domain: "GreywallLease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing symlinked native state directory"])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw NSError(domain: "GreywallLease", code: 2, userInfo: [NSLocalizedDescriptionKey: "Another native session is active; disable/finish it first"])
        }
    }
    deinit { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
}
