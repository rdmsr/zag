const std = @import("std");
const r = @import("root");
const rtl = @import("rtl");
const ke = r.ke;

fn LockTemplate(comptime T: type) type {
    comptime {
        if (!@hasDecl(T, "acquire_no_ipl")) @compileError("lock backend must implement acquire_no_ipl");
        if (!@hasDecl(T, "release_no_ipl")) @compileError("lock backend must implement release_no_ipl");
        if (!@hasDecl(T, "try_acquire_no_ipl")) @compileError("lock backend must implement try_acquire_no_ipl");
        if (!@hasDecl(T, "is_locked")) @compileError("lock backend must implement is_locked");
    }

    return struct {
        inner: T,

        const Self = @This();

        pub fn init() Self {
            return .{ .inner = T.init() };
        }

        /// Acquire the lock, raising IPL to `ipl`. Returns the previous IPL.
        pub fn acquire_at(self: *Self, ipl: ke.Ipl) ke.Ipl {
            const old_ipl = ke.ipl.raise(ipl);
            self.inner.acquire_no_ipl();
            return old_ipl;
        }

        /// Acquire the lock, raising IPL to `.Dispatch`. Returns the previous IPL.
        pub fn acquire(self: *Self) ke.Ipl {
            return self.acquire_at(.Dispatch);
        }

        /// Release the lock and restore IPL to `ipl`.
        pub fn release(self: *Self, ipl: ke.Ipl) void {
            self.inner.release_no_ipl();
            ke.ipl.lower(ipl);
        }

        /// Try to acquire the lock at IPL `.Dispatch`.
        /// Returns the previous IPL on success, null if the lock is already held.
        pub fn try_acquire(self: *Self) ?ke.Ipl {
            const old_ipl = ke.ipl.raise(.Dispatch);
            if (self.inner.try_acquire_no_ipl()) {
                return old_ipl;
            } else {
                ke.ipl.lower(old_ipl);
                return null;
            }
        }

        /// Acquire the lock without changing the IPL.
        pub fn acquire_no_ipl(self: *Self) void {
            self.inner.acquire_no_ipl();
        }

        /// Release the lock without changing the IPL.
        pub fn release_no_ipl(self: *Self) void {
            self.inner.release_no_ipl();
        }

        /// Try to acquire the lock without changing the IPL.
        /// Returns true if the lock was acquired.
        pub fn try_acquire_no_ipl(self: *Self) bool {
            return self.inner.try_acquire_no_ipl();
        }

        /// Returns true if the lock is currently held.
        pub fn is_locked(self: *Self) bool {
            return self.inner.is_locked();
        }
    };
}

/// Simple Spin lock implementation.
pub const SpinLock = LockTemplate(struct {
    locked: u8,

    const Self = @This();

    pub fn init() Self {
        return .{
            .locked = 0,
        };
    }

    /// Acquire the lock without changing the IPL.
    pub fn acquire_no_ipl(self: *Self) void {
        while (true) {
            if (@cmpxchgWeak(u8, &self.locked, 0, 1, .acquire, .monotonic) == null)
                return;

            while (@atomicLoad(u8, &self.locked, .monotonic) != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }

    /// Release the lock without changing the IPL.
    pub fn release_no_ipl(self: *Self) void {
        @atomicStore(u8, &self.locked, 0, .release);
    }

    /// Try to acquire the lock. Return true if lock was acquired.
    pub fn try_acquire_no_ipl(self: *Self) bool {
        return @cmpxchgStrong(u8, &self.locked, 0, 1, .acquire, .monotonic) == null;
    }

    pub fn is_locked(self: *Self) bool {
        return @atomicLoad(u8, &self.locked, .monotonic) == 1;
    }
});

const McsNode = struct {
    next: std.atomic.Value(?*McsNode),
    locked: std.atomic.Value(u8),
};

const PerCpu = struct {
    nodes: [4]McsNode,
    curr_idx: u32,
};

const pcpu = ke.CpuLocal(PerCpu, undefined);

export const qspinlock_percpu_init linksection(r.percpu_init) = &init_cpu;

/// Initialize a CPU for use by the scheduler.
fn init_cpu() linksection(r.init) callconv(.c) void {
    var cpu = pcpu.local();
    cpu.curr_idx = 0;

    for (&cpu.nodes) |*node| {
        node.locked.raw = 0;
        node.next.raw = null;
    }
}

/// Queued spin lock implementation.
/// See https://rdmsr.github.io/writing/qspinlocks
pub const QSpinLock = LockTemplate(struct {
    const Tail = packed struct(u16) {
        idx: u2,
        cpu: u14,
    };

    const Data = extern union {
        val: std.atomic.Value(u32),
        low_word: extern struct {
            locked: std.atomic.Value(u8),
            pending: std.atomic.Value(u8),
        },
        split: extern struct {
            locked_pending: std.atomic.Value(u16),
            tail: std.atomic.Value(u16),
        },
    };

    const locked_val: u32 = 1;
    const locked_mask: u32 = 0xFF;
    const tail_mask: u32 = 0xFFFF0000;
    const pending_mask: u32 = 0x0000FF00;
    const pending_val: u32 = 0x00000100;
    const pending_loops = 512;

    const Self = @This();

    data: Data,

    pub fn init() Self {
        return .{ .data = .{ .val = std.atomic.Value(u32).init(0) } };
    }

    pub fn acquire_no_ipl(self: *Self) void {
        // Fast path: try to acquire the lock.
        var v = self.data.val.cmpxchgStrong(0, locked_val, .acquire, .monotonic) orelse return;

        // Medium path: if only pending is set, the pending waiter is
        // in the process of clearing pending and setting `locked` to take
        // ownership. Spin for a bit to let the transition complete.
        if (v == pending_val) {
            for (0..pending_loops) |_| {
                v = self.data.val.load(.monotonic);
                if (v != pending_val) break;
                std.atomic.spinLoopHint();
            }
        }

        if ((v & ~locked_mask) != 0) {
            // If another bit is set, this means there is another waiter.
            // Go to the slow path.
            self.queue();
            return;
        }

        // No one is contending, set the pending bit.
        v = self.data.val.fetchOr(pending_val, .acquire);

        // We may have raced and someone modified the lock between our initial
        // check and the fetchOr. Validate the value.
        if ((v & ~locked_mask) != 0) {
            @branchHint(.unlikely);

            if ((v & pending_mask) == 0) {
                // We set the pending bit but we shouldn't have, undo it.
                _ = self.data.val.fetchAnd(~pending_val, .release);
            }

            self.queue();
            return;
        }

        // Spin on locked.
        if ((v & locked_mask) != 0) {
            while (self.data.low_word.locked.load(.acquire) != 0) {
                std.atomic.spinLoopHint();
            }
        }

        // Clear pending and set locked.
        self.data.split.locked_pending.store(1, .release);
    }

    pub fn release_no_ipl(self: *Self) void {
        self.data.low_word.locked.store(0, .release);
    }

    pub fn try_acquire_no_ipl(self: *Self) bool {
        return self.data.val.cmpxchgStrong(0, locked_val, .acquire, .monotonic) == null;
    }

    pub fn is_locked(self: *Self) bool {
        return self.data.low_word.locked.load(.monotonic) != 0;
    }

    fn queue(self: *Self) void {
        // Claim an index from our CPU.
        const idx = pcpu.local().curr_idx;
        pcpu.local().curr_idx += 1;

        // Don't forget to release it once we're done.
        defer pcpu.local().curr_idx -= 1;

        if (idx >= 4) {
            // Exhausted all indices, spin.
            while (true) {
                _ = self.data.val.cmpxchgWeak(0, locked_val, .acquire, .monotonic) orelse break;
                std.atomic.spinLoopHint();
            }

            return;
        }

        var node = &pcpu.local().nodes[idx];
        node.locked.store(0, .monotonic);
        node.next.store(null, .monotonic);

        // Try one last time.
        if (self.try_acquire_no_ipl()) {
            return;
        }

        // Store cpu + 1 so that we can distinguish from an empty tail field.
        rtl.barrier.wmb();
        const tail: u16 = @bitCast(Tail{ .cpu = @intCast(ke.cpu.current() + 1), .idx = @intCast(idx) });
        const old: Tail = @bitCast(self.data.split.tail.swap(tail, .acq_rel));

        if (old.cpu != 0) {
            // Someone else is already waiting, link ourselves to their node.
            const prev = &pcpu.remote(@intCast(old.cpu)).nodes[old.idx];

            prev.next.store(node, .release);

            // Spin until the previous waiter passes ownership to us.
            while (node.locked.load(.acquire) == 0) {
                std.atomic.spinLoopHint();
            }
        }

        // We are now at the head of the queue.
        // Spin on the main lock word until both locked and pending are clear.
        var v = self.data.val.load(.acquire);

        while ((v & (locked_mask | pending_mask)) != 0) {
            std.atomic.spinLoopHint();
            v = self.data.val.load(.acquire);
        }

        if ((v & tail_mask) == @as(u32, tail) << 16) {
            // We are the only waiter in the queue.
            // Try to claim the lock and clear the tail atomically.
            if (self.data.val.cmpxchgStrong(v, locked_val, .acquire, .monotonic) == null) {
                return;
            }
        }

        // There's someone else waiting behind us, we can't clear the tail.
        // Set locked and wake our successor.
        self.data.low_word.locked.store(1, .release);

        // Spin until next is set. There is a race in the two-step enqueue:
        // a successor may have swapped the tail but not yet written their
        // next pointer.
        var next: ?*McsNode = null;

        while (true) {
            next = node.next.load(.acquire);
            if (next != null) break;
            std.atomic.spinLoopHint();
        }

        next.?.locked.store(1, .release);
    }
});
