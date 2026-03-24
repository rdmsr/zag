//! Timer object implementation.
//! Timer objects are useful when one wants to wait a fixed amount of time for an event to occur.
const std = @import("std");
const rtl = @import("rtl");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;
const pl = b.pl;

const PerCpu = struct {
    /// Heap of pending timers on this CPU.
    timers: rtl.PairingHeap(.min, ki.timer.cmp_timer),
    /// Lock over the timer heap.
    lock: ke.SpinLock,
    dpc: ke.Dpc,
};

pub const Timer = struct {
    pub const State = enum(u8) {
        /// The timer is currently being handled.
        Running,
        /// The timer is currently enqueued.
        Pending,
        /// The timer was stopped.
        Stopped,
    };

    hdr: ki.wait.DispatchHeader,

    /// Timer state.
    state: std.atomic.Value(State),
    /// When the timer is bound to expire.
    deadline: b.Nanoseconds,
    /// Attached DPC.
    dpc: ?*ke.Dpc,
    /// Intrusive pairing heap node.
    node: rtl.pairing_heap.Node,
    /// CPU this timer is enqueued on.
    cpu: ?*PerCpu,

    pub fn init(self: *Timer) void {
        self.* = .{
            .hdr = undefined,
            .state = .init(.Stopped),
            .deadline = 0,
            .dpc = null,
            .node = .{},
            .cpu = null,
        };

        self.hdr.init(.Notification);
    }
};

const percpu = ke.CpuLocal(PerCpu, .{
    .timers = .init(),
    .lock = .init(),
    .dpc = .init(handle_expiry),
});

/// Start a timer with an expiration time.
/// A DPC that will be enqueued upon expiration can be passed.
pub fn set(timer: *Timer, time: b.Nanoseconds, dpc: ?*ke.Dpc) void {
    const ipl = timer.hdr.lock.acquire();
    defer timer.hdr.lock.release(ipl);

    const cpu = percpu.local();

    if (timer.state.cmpxchgStrong(.Stopped, .Pending, .acquire, .monotonic) != null) {
        // Could not set the timer.
        return;
    }

    cpu.lock.acquire_no_ipl();
    defer cpu.lock.release_no_ipl();

    // Initialize the timer.
    timer.deadline = ke.timecounter.read_time_nano() + time;

    timer.cpu = cpu;
    timer.dpc = dpc;
    timer.hdr.signaled = 0;

    cpu.timers.insert(&timer.node);

    if (cpu.timers.root == &timer.node) {
        // This is the earliest timer to expire, arm the hardware timer.
        pl.arm_timer(time);
    }

    // Locks dropped
}

/// Cancel a timer.
pub fn cancel(timer: *Timer) void {
    const old_state = timer.state.load(.monotonic);

    if (old_state == .Stopped or old_state == .Running) {
        // Already stopped or currently executing.
        return;
    }

    const ipl = timer.hdr.lock.acquire();
    defer timer.hdr.lock.release(ipl);

    if (timer.state.cmpxchgStrong(.Pending, .Stopped, .acquire, .monotonic) != null) {
        // Something changed, it probably expired.
        return;
    }

    if (timer.cpu) |cpu| {
        // Dequeue the timer.
        cpu.lock.acquire_no_ipl();

        cpu.timers.remove(&timer.node);
        timer.cpu = null;

        cpu.lock.release_no_ipl();
    }

    // Lock dropped
}

/// Compare two timers.
pub fn cmp_timer(a: *rtl.pairing_heap.Node, b_: *rtl.pairing_heap.Node) std.math.Order {
    const timer_a: *Timer = @fieldParentPtr("node", a);
    const timer_b: *Timer = @fieldParentPtr("node", b_);

    return std.math.order(timer_a.deadline, timer_b.deadline);
}

/// Called by the platform on a clock interrupt.
pub fn clock() void {
    ke.dpc.enqueue(&percpu.local().dpc, null);
}

// Called in a DPC when a timer has expired.
fn handle_expiry(_: ?*anyopaque) void {
    std.debug.assert(ke.curcpu().ipl == .Dispatch);
    const cpu = percpu.local();

    while (true) {
        const curtime = ke.timecounter.read_time_nano();

        cpu.lock.acquire_no_ipl();

        // Get the timer that expires the soonest.
        const timer_node = cpu.timers.root orelse {
            cpu.lock.release_no_ipl();
            return;
        };

        const timer: *Timer = @fieldParentPtr("node", timer_node);

        // If the timer expires more than 1ms in the future, consider it not yet due.
        // Sub-millisecond differences are close enough to expire immediately.
        if (timer.deadline > curtime and timer.deadline - curtime > std.time.ns_per_ms) {
            const next = timer;
            cpu.lock.release_no_ipl();

            // Re-check in case the timer expired while we were here.
            const now = ke.timecounter.read_time_nano();
            if (next.deadline <= now or next.deadline - now <= std.time.ns_per_ms) {
                continue; // expired in the meantime, loop again
            }

            std.debug.assert(next.deadline > now);
            pl.arm_timer(next.deadline - now);
            return;
        }

        _ = cpu.timers.pop();
        cpu.lock.release_no_ipl();

        if (timer.state.cmpxchgStrong(.Pending, .Running, .acquire, .monotonic) != null) {
            // Timer must've been canceled.
            continue;
        }

        timer.hdr.lock.acquire_no_ipl();

        // Set signaled.
        timer.hdr.signaled = 1;
        timer.cpu = null;

        // Wake whomever was waiting on the timer.
        ki.wait.satisfy_wait(&timer.hdr);

        timer.state.store(.Stopped, .release);

        if (timer.dpc) |dpc| ke.dpc.enqueue(dpc, null);
        timer.hdr.lock.release_no_ipl();
    }
}
