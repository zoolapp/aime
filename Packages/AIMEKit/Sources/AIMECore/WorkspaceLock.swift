public import Foundation

/// Advisory cross-process lock (flock) guarding writes to one AIME user directory.
/// The input method and every `aime` CLI command that deploys, imports, syncs or
/// installs take it, so there is only ever one writer of `build/` and the userdb.
public final class WorkspaceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Returns nil when another process holds the lock and `wait` is false.
    public static func acquire(_ paths: AIMEPaths, wait: Bool = false) -> WorkspaceLock? {
        try? FileManager.default.createDirectory(at: paths.aimeDir, withIntermediateDirectories: true)
        let path = paths.aimeDir.appendingPathComponent(".lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            close(fd)
            return nil
        }
        return WorkspaceLock(descriptor: fd)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
