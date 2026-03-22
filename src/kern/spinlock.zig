const std = @import("std");
const b = @import("base");
const ke = b.ke;

/// Simple Spin lock implementation.
pub const SpinLock = struct {
    locked: u8,

    pub fn init() SpinLock {
        return .{
            .locked = 0,
        };
    }

    /// Acquire the lock at IPL `ipl`.
    pub fn acquire_at(self: *SpinLock, ipl: ke.Ipl) ke.Ipl {
        const old_ipl = ke.ipl.raise(ipl);

        self.acquire_no_ipl();

        return old_ipl;
    }

    /// Acquire the lock at IPL `.Dispatch`.
    pub fn acquire(self: *SpinLock) ke.Ipl {
        return self.acquire_at(.Dispatch);
    }

    /// Release the lock at IPL `ipl`.
    pub fn release(self: *SpinLock, ipl: ke.Ipl) void {
        ke.ipl.lower(ipl);
        self.release_no_ipl();
    }

    /// Acquire the lock without changing the IPL.
    pub fn acquire_no_ipl(self: *SpinLock) void {
        while (true) {
            if (@cmpxchgWeak(u8, &self.locked, 0, 1, .acquire, .monotonic) == null)
                return;

            while (@atomicLoad(u8, &self.locked, .monotonic) != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Release the lock without changing the IPL.
    pub fn release_no_ipl(self: *SpinLock) void {
        @atomicStore(u8, &self.locked, 0, .release);
    }

    /// Try to acquire the lock. Return true if lock was acquired.
    pub fn try_acquire(self: *SpinLock) bool {
        return @cmpxchgStrong(u8, &self.locked, 0, 1, .acquire, .monotonic) == null;
    }

    pub fn is_locked(self: *SpinLock) bool {
        return @atomicLoad(u8, &self.locked, .monotonic) == 1;
    }
};
