//! Adaptive lock implementation.

const std = @import("std");
const rtl = @import("rtl");
const config = @import("config");

const ke = @import("root").ke;
const kep = ke.private;

/// Number of spins before blocking.
const optimistic_spins = 100;

pub const Mutex = struct {
    /// The thread currently holding the mutex, null if unlocked.
    owner: std.atomic.Value(?*ke.Thread),
    wd: kep.warden.LockData,

    pub fn init(class: []const u8) Mutex {
        if (config.warden) {
            const cl = kep.warden.find_or_create_lock_class(class);
            return .{
                .owner = std.atomic.Value(?*ke.Thread).init(null),
                .wd = cl,
            };
        }

        return .{ .owner = std.atomic.Value(?*ke.Thread).init(null) };
    }

    pub fn is_locked(self: *Mutex) bool {
        return self.owner.load(.monotonic) != null;
    }

    pub fn acquire(m: *Mutex) void {
        const ipl = ke.ipl.raise(.Dispatch);
        const curtd = kep.sched.percpu.local().current_thread orelse
            unreachable;

        if (config.warden) {
            kep.warden.check(m.wd, .Lock);
        }

        defer if (config.warden) {
            kep.warden.acquired(m, m.wd, .Lock);
        };

        // Very fast path: the lock is uncontended and we can acquire it
        //immediately.
        const cur_owner = m.owner.cmpxchgStrong(
            null,
            curtd,
            .acquire,
            .monotonic,
        );

        if (cur_owner == null) {
            ke.ipl.lower(ipl);
            return;
        }

        // Fast path: Try to acquire without a turnstile by spinning a bit.
        for (0..optimistic_spins) |_| {
            if (m.owner.load(.monotonic) != null) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (m.owner.cmpxchgWeak(
                null,
                curtd,
                .acquire,
                .monotonic,
            ) != null) {
                continue;
            }

            ke.ipl.lower(ipl);
            return;
        }

        // Slow path: contended, block on a turnstile.
        while (true) {
            const ts = kep.turnstile.lookup(m);
            const owner = m.owner.load(.monotonic);

            if (owner == null) {
                // Lock was released between lookup and here.
                kep.turnstile.exit(m, ts);
                if (m.owner.cmpxchgStrong(
                    null,
                    curtd,
                    .acquire,
                    .monotonic,
                ) == null) {
                    break;
                }
                continue;
            }

            // Block until woken.
            kep.turnstile.block(
                ts,
                m,
                .{ .single = owner orelse unreachable },
                .Exclusive,
            );

            // Re-try acquisition after wakeup.
            if (m.owner.cmpxchgStrong(
                null,
                curtd,
                .acquire,
                .monotonic,
            ) == null) {
                break;
            }
        }

        ke.ipl.lower(ipl);
    }

    pub fn release(m: *Mutex) void {
        const ipl = ke.ipl.raise(.Dispatch);
        const ts = kep.turnstile.lookup(m);

        m.owner.store(null, .release);

        defer if (config.warden) {
            kep.warden.released(m, .Lock);
        };

        if (ts == null) {
            kep.turnstile.exit(m, ts);
            ke.ipl.lower(ipl);
            return;
        }

        var waiters: rtl.List = undefined;
        const turn = ts orelse unreachable;

        // Note: wake up all waiters.
        // This so-called "lock barging" (name from WTF::ParkingLot) has been
        // to be better because this avoids lock convoys,
        // see this mysterious 70s paper:
        // https://dl.acm.org/doi/pdf/10.1145/850657.850659
        kep.turnstile.signal(
            turn,
            .Exclusive,
            turn.waiters,
            null,
            &waiters,
        );

        kep.turnstile.exit(m, ts);
        kep.turnstile.wakeup(&waiters);
        ke.ipl.lower(ipl);
    }
};
