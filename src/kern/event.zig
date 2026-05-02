const ke = @import("root").ke;
const ki = ke.private;

/// Generic waitable Event, exported for use everywhere in the kernel.
pub const Event = struct {
    hdr: ki.wait.DispatchHeader,

    const Self = @This();

    pub const Type = enum {
        /// Wake only one waiter.
        Synchronization,
        /// Wake all waiters.
        Notification,
    };

    /// Initialize an event with a specified type.
    pub fn init(self: *Self, @"type": Type) void {
        self.hdr.init(switch (@"type") {
            .Synchronization => .Synchronization,
            .Notification => .Notification,
        });
    }

    /// Signal an event, waking its waiter(s).
    pub fn signal(self: *Self) void {
        const ipl = self.hdr.lock.acquire();
        self.hdr.signaled = 1;
        ki.wait.satisfy_wait(&self.hdr);
        self.hdr.lock.release(ipl);
    }
};
