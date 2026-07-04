// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Foundation

/// Enforces single-instance via an exclusive, non-blocking flock() on a file
/// in Application Support - the macOS equivalent of the Windows build's
/// named Mutex. flock() is atomic at the kernel level, unlike a
/// check-then-act query (e.g. counting NSRunningApplications with a matching
/// bundle identifier), which has a race window between two processes
/// launching near-simultaneously that could let both pass the check. The
/// lock is released automatically when the holding process exits or
/// crashes, since it's tied to the open file descriptor.
final class SingleInstanceLock {
    private var fileDescriptor: Int32 = -1

    /// - Returns: true if this process now holds the lock (no other pype
    ///   instance is running), false if another instance already holds it.
    func acquire() -> Bool {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pype", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)

        let lockPath = supportDir.appendingPathComponent("pype.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd != -1 else {
            // Couldn't even open the lock file (e.g. permissions issue) -
            // fail open rather than blocking startup over it.
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            fileDescriptor = fd
            return true
        }

        close(fd)
        return false
    }

    deinit {
        if fileDescriptor != -1 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}
