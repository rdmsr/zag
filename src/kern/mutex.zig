const std = @import("std");
const ke = @import("root").ke;
const ki = ke.private;

pub const Mutex = struct {
    /// The thread currently holding the mutex, null if unlocked.
    owner: std.atomic.Value(?*ke.Thread),

    pub fn init() Mutex {
        return .{ .owner = .init(null) };
    }

    pub fn acquire(m: *Mutex) void {
        const ipl = ke.ipl.raise(.Dispatch);
        const curtd = ki.sched.percpu.local().current_thread.?;

        // Fast path: try to acquire without a turnstile.
        if (m.owner.cmpxchgStrong(null, curtd, .acquire, .monotonic) == null) {
            ke.ipl.lower(ipl);
            return;
        }

        // Slow path: contended, block on a turnstile.
        while (true) {
            const ts = ki.turnstile.lookup(m);
            const owner = m.owner.load(.monotonic);

            if (owner == null) {
                // Lock was released between lookup and here.
                ki.turnstile.exit(m);
                if (m.owner.cmpxchgStrong(null, curtd, .acquire, .monotonic) == null) {
                    break;
                }
                continue;
            }

            // Block until woken.
            ki.turnstile.block(ts, m, owner.?, .Shared);

            // Re-try acquisition after wakeup.
            if (m.owner.cmpxchgStrong(null, curtd, .acquire, .monotonic) == null) {
                break;
            }
        }

        ke.ipl.lower(ipl);
    }

    pub fn release(m: *Mutex) void {
        const ipl = ke.ipl.raise(.Dispatch);

        const ts = ki.turnstile.lookup(m);

        m.owner.store(null, .release);

        if (ts == null) {
            ki.turnstile.exit(m);
            ke.ipl.lower(ipl);
            return;
        }

        // Note: wake up all waiters. This so-called "lock barging" (name from WTF::ParkingLot)
        // has been shown to be better because this avoids lock convoys, see this mysterious 70s paper:
        // https://dl.acm.org/doi/pdf/10.1145/850657.850659
        ki.turnstile.wakeup(ts.?, .Exlusive, ts.?.waiters, null);

        ke.ipl.lower(ipl);
    }
};
