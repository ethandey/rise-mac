import Foundation
import Darwin

/// Ensures only one Rise *menu bar* process runs at a time.
/// One-shot breaks (`--layer`) may run alongside the menu bar (max 2 processes).
enum SingleInstance {
    private static var heldHandle: FileHandle?

    /// Lock path next to the install root (or /tmp fallback).
    static var menubarLockPath: String {
        let root = SystemControl.root
        let dir = (root as NSString).appendingPathComponent("data")
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        return (dir as NSString).appendingPathComponent("rise-menubar.lock")
    }

    /// Acquire exclusive non-blocking lock for menu bar mode.
    /// Returns false if another menu bar instance already holds the lock.
    @discardableResult
    static func acquireMenubar() -> Bool {
        let path = menubarLockPath
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            fputs("rise: could not open lock \(path)\n", stderr)
            return true // fail open so user isn't bricked
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        // Truncate + write pid for debugging
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        let pid = "\(getpid())\n"
        _ = pid.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }

        // Keep fd open for process lifetime (lock held until exit)
        heldHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return true
    }

    static func releaseMenubar() {
        heldHandle?.closeFile()
        heldHandle = nil
    }
}
