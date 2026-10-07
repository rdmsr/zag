//! Kernel events.

const ke = @import("root").ke;
const kep = ke.private;

/// Generic waitable Event, exported for use everywhere in the kernel.
pub const Event = struct {
    hdr: kep.wait.DispatchHeader,

    pub const Type = enum {
        /// Wake only one waiter and decrease signaled.
        Synchronization,
        /// Wake all waiters a keep signaled high.
        Notification,
    };

    /// Initialize an event with a specified type.
    pub fn init(self: *Event, @"type": Type) void {
        self.hdr.init(switch (@"type") {
            .Synchronization => .Synchronization,
            .Notification => .Notification,
        });
    }

    /// Signal an event, waking its waiter(s).
    pub fn signal(self: *Event) void {
        const ipl = self.hdr.lock.acquire();
        self.hdr.signaled = 1;
        kep.wait.satisfy_wait(&self.hdr);
        self.hdr.lock.release(ipl);
    }

    /// Reset an event.
    pub fn reset(self: *Event) void {
        const ipl = self.hdr.lock.acquire();
        self.hdr.signaled = 0;
        self.hdr.lock.release(ipl);
    }
};
