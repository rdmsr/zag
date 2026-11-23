//! Kernel process objects.
//!
//! This file implements functionality related to the management of kernel
//! process objects. Kernel process objects are the lower layer of process
//! management and can be waited upon for completion fo the process.

const std = @import("std");
const assert = std.debug.assert;

const r = @import("root");
const ke = r.ke;
const kep = ke.private;

const rtl = @import("rtl");

/// Represents a process object.
pub const Process = struct {
    hdr: kep.wait.DispatchHeader,

    /// The process's address space.
    address_space: ke.AddressSpace,

    /// List of threads attached to this process.
    threads: rtl.List,

    /// CPUs this process is active on.
    active_cpus: ke.CpuMask,

    /// CPUs this process can run on.
    affinity: ke.CpuMask,

    /// Base priority assigned to threads.
    base_priority: ke.Priority,

    const Options = struct {
        base_priority: ke.Priority,
        affinity: ke.CpuMask,
        address_space: ke.AddressSpace,
    };

    pub fn init(self: *Process, options: Options) void {
        self.* = .{
            .hdr = undefined,
            .threads = undefined,
            .active_cpus = ke.CpuMask.init(false),
            .affinity = options.affinity,
            .base_priority = options.base_priority,
            .address_space = options.address_space,
        };

        self.threads.init();
        self.hdr.init(.Notification);
    }

    /// Attach a thread to the given process.
    /// This must be called at a point where exclusive custody of the
    /// thread exists, i.e at thread creation time.
    ///
    /// N.B.: It would not be correct for the caller to lock the thread here,
    /// as that would be an ordering inversion of object -> thread, though
    /// without deadlocking per-se as the thread being inserted into the process
    /// cannot also be waiting on it.
    pub fn attach(self: *Process, thread: *ke.Thread) void {
        const ipl = self.hdr.lock.acquire();
        defer self.hdr.lock.release(ipl);

        self.threads.insert(&thread.process_link);
    }

    /// Signal a process object and satisfy waits on it.
    pub fn set(self: *Process) void {
        const ipl = self.hdr.lock.acquire();
        defer self.hdr.lock.release(ipl);

        self.hdr.signaled = 1;
        self.hdr.satisfy_wait();
    }
};
