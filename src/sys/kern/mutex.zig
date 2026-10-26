//! Adaptive lock implementation.

const rtl = @import("rtl");
const config = @import("config");

const std = @import("std");
const assert = std.debug.assert;

const ke = @import("root").ke;
const kep = ke.private;

/// Number of spins while the lock's owner is running before blocking.
// TODO: tune this!
const optimistic_spins = 4000;

/// owner | waiters (bit 0)
const State = packed struct(usize) {
    value: usize = 0,

    const waiters: usize = 1;
    const uncontended: State = @fromBackingInt(0);

    fn from(td: *ke.Thread) State {
        return .{ .value = @intFromPtr(td) };
    }

    inline fn owner(s: State) *ke.Thread {
        return @ptrFromInt(s.value & ~waiters);
    }

    inline fn has_waiters(s: State) bool {
        return s.value & waiters != 0;
    }

    inline fn set_waiters(s: State) State {
        return .{ .value = s.value | waiters };
    }

    inline fn clear_waiters(s: State) State {
        return .{ .value = s.value & ~waiters };
    }
};

pub const Mutex = struct {
    /// The thread currently holding the mutex, null if unlocked.
    state: std.atomic.Value(State),
    wd: kep.warden.LockData = undefined,

    pub fn init(class: []const u8) Mutex {
        if (config.warden) {
            const cl = kep.warden.find_or_create_lock_class(class);
            return .{
                .state = std.atomic.Value(State).init(.{}),
                .wd = cl,
            };
        }

        return .{ .state = std.atomic.Value(State).init(.{}) };
    }

    /// Return whether the lock is currently held.
    pub fn is_locked(self: *Mutex) bool {
        return self.state.load(.monotonic) != State.uncontended;
    }

    /// Try to acquire the lock.
    /// Returns true on success.
    pub fn try_acquire(self: *Mutex) bool {
        const curtd = ke.thread.current();
        if (self.state.cmpxchgStrong(
            State.uncontended,
            State.from(curtd),
            .acquire,
            .monotonic,
        ) == null) {
            if (config.warden) {
                kep.warden.acquired(self, self.wd, .Lock);
            }

            return true;
        }

        return false;
    }

    /// Acquire the lock.
    pub inline fn acquire(m: *Mutex) void {
        const curtd = ke.thread.current();

        if (config.warden) {
            kep.warden.check(m.wd, .Lock);
        }

        defer if (config.warden) {
            kep.warden.acquired(m, m.wd, .Lock);
        };

        // Fast path: the lock is uncontended and we can acquire it
        // immediately.
        _ = m.state.cmpxchgStrong(
            State.uncontended,
            State.from(curtd),
            .acquire,
            .monotonic,
        ) orelse {
            @branchHint(.likely);

            // We got the lock.
            return;
        };

        // Nope, go to the slow path.
        m.acquire_slow();
    }

    fn acquire_slow(m: *Mutex) void {
        @branchHint(.unlikely);

        const curtd = ke.thread.current();

        retry: while (true) {
            var state = m.state.load(.monotonic);

            if (state == State.uncontended) {
                // The lock seems free, retry acquiring it via CAS.
                if (m.state.cmpxchgStrong(
                    State.uncontended,
                    State.from(curtd),
                    .acquire,
                    .monotonic,
                ) == null) {
                    break;
                }
            }

            // Still contended, lock the turnstile chain.
            var ipl = ke.ipl.raise(.Dispatch);
            const chain = kep.turnstile.lock_chain(m);

            state = m.state.load(.monotonic);

            if (state == State.uncontended) {
                // Something changed, retry acquiring.
                kep.turnstile.unlock_chain(chain);
                ke.ipl.lower(ipl);
                continue :retry;
            }

            // Set the waiters bit so that release() will also take the lock.
            waiters: while (!state.has_waiters()) {
                if (state == State.uncontended) {
                    kep.turnstile.unlock_chain(chain);
                    ke.ipl.lower(ipl);
                    continue :retry;
                }

                const marked = state.set_waiters();
                state = m.state.cmpxchgWeak(
                    state,
                    marked,
                    .monotonic,
                    .monotonic,
                ) orelse {
                    state = marked;
                    break :waiters;
                };
            }

            // Look up the current owner, there is a guarantee that the thread
            // pointer is still valid while we hold the lock here because
            // upon release, whomever holds the lock right now will notice the
            // waiters bit and try to take the same chain lock.
            const owner = state.owner();

            if (owner.state.load(.monotonic) == .Running) {
                const cpu = owner.cpu orelse unreachable;
                const cpu_curtd = kep.sched.current_thread.remote(cpu);

                // The lock's owner is running, spin adaptively
                // until it stops running or we run out of gas.
                kep.turnstile.unlock_chain(chain);
                ke.ipl.lower(ipl);

                var gas: usize = 0;

                while (rtl.mem.racy_read(
                    ?*ke.Thread,
                    cpu_curtd,
                ) == owner and gas < optimistic_spins) : (gas += 1) {
                    if (m.state.load(.monotonic) == State.uncontended) {
                        // Got released, retry acquiring it.
                        continue :retry;
                    }

                    std.atomic.spinLoopHint();
                }

                // Couldn't get it via adaptive spinning, now actually block
                // on a turnstile.

                ipl = ke.ipl.raise(.Dispatch);
                _ = kep.turnstile.lock_chain(m);

                if (m.state.load(.monotonic) != state) {
                    // Could've gotten released in the meantime, try again.
                    kep.turnstile.unlock_chain(chain);
                    ke.ipl.lower(ipl);
                    continue :retry;
                }
            }

            const ts = kep.turnstile.lookup_locked(m, chain);

            if (m.state.load(.monotonic) != state) {
                // Something changed between lookup and here.
                kep.turnstile.exit(m, ts);
                ke.ipl.lower(ipl);
                continue :retry;
            }

            // Block until woken.
            kep.turnstile.block(
                ts,
                m,
                .{ .single = state.owner() },
                .Exclusive,
            );
        }
    }

    /// Release the lock.
    pub inline fn release(m: *Mutex) void {
        const old = m.state.swap(State.uncontended, .release);

        if (old.has_waiters()) {
            m.release_slow();
        }

        if (config.warden) {
            kep.warden.released(m, .Lock);
        }
    }

    /// Called when there were waiters on the lock that we need to wake.
    fn release_slow(m: *Mutex) void {
        @branchHint(.unlikely);

        // Look up the turnstile.
        const ipl = ke.ipl.raise(.Dispatch);
        const ts = kep.turnstile.lookup(m);

        if (ts == null) {
            kep.turnstile.exit(m, ts);
            ke.ipl.lower(ipl);
            return;
        }

        var waiters: rtl.List = undefined;
        const turn = ts orelse unreachable;

        // Wake ALL the waiters. This so-called "lock barging" is meant to avoid
        // lock convoys.
        //
        // See this mysterious 70s paper:
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
