//! Timer object implementation.
//! Timer objects are useful when one wants to wait a given amount of time for
//! an event to occur.
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const kep = ke.private;
const pl = r.pl;

const std = @import("std");
const assert = std.debug.assert;

const TimerHeap = rtl.PairingHeapType(.Min, kep.timer.cmp_timer);

const PerCpu = struct {
    /// Heap of pending timers on this CPU.
    timers: TimerHeap,
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
        /// The timer is no longer enqueued or being signaled.
        Stopped,
    };

    hdr: kep.wait.DispatchHeader,

    /// Timer state.
    state: std.atomic.Value(State),
    /// When the timer is bound to expire.
    deadline: rtl.Timestamp,
    /// Attached DPC.
    dpc: ?*ke.Dpc,
    /// Intrusive pairing heap node.
    node: rtl.pairing_heap.Node,
    /// CPU this timer is enqueued on.
    cpu: ?*PerCpu,

    pub fn init(self: *Timer) void {
        self.* = .{
            .hdr = undefined,
            .state = std.atomic.Value(State).init(.Stopped),
            .deadline = .{ .value = 0 },
            .dpc = null,
            .node = .{},
            .cpu = null,
        };

        self.hdr.init(.Notification);
    }
};

const percpu = ke.CpuLocalType(PerCpu, .{
    .timers = TimerHeap.init(),
    .lock = undefined,
    .dpc = ke.Dpc.init(handle_expiry),
});

fn pcpu_init() linksection(r.init) void {
    percpu.local().lock = ke.SpinLock.init("timers");
}

comptime {
    _ = r.percpu_init_set.insert(&pcpu_init);
}

const Options = struct {
    dpc: ?*ke.Dpc = null,
};

/// Start a timer with an expiration time.
/// A DPC that will be enqueued upon expiration can be passed.
pub fn set(timer: *Timer, duration: rtl.Duration, opts: Options) void {
    const ipl = timer.hdr.lock.acquire();
    defer timer.hdr.lock.release(ipl);

    const cpu = percpu.local();

    if (timer.state.load(.monotonic) != .Stopped) {
        return;
    }
    timer.state.store(.Pending, .monotonic);

    cpu.lock.acquire_no_ipl();
    defer cpu.lock.release_no_ipl();

    // Initialize the timer.
    timer.deadline = ke.time.read_time().add(duration);

    timer.cpu = cpu;
    timer.dpc = opts.dpc;
    timer.hdr.signaled = 0;

    cpu.timers.insert(&timer.node);

    if (cpu.timers.root == &timer.node) {
        // This is the earliest timer to expire, arm the hardware timer.
        pl.arm_timer(duration);
    }

    // Locks dropped
}

/// Cancel a timer.
pub fn cancel(timer: *Timer) void {
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    while (true) {
        timer.hdr.lock.acquire_no_ipl();

        switch (timer.state.load(.acquire)) {
            .Stopped => {
                timer.hdr.lock.release_no_ipl();
                return;
            },
            .Running => {
                // Wait until the timer finishes running.
                timer.hdr.lock.release_no_ipl();
                while (timer.state.load(.acquire) == .Running) {
                    std.atomic.spinLoopHint();
                }
            },
            .Pending => {
                const cpu = timer.cpu orelse unreachable;
                cpu.lock.acquire_no_ipl();

                // Re-check under the lock.
                if (timer.state.load(.acquire) == .Pending) {
                    cpu.timers.remove(&timer.node);
                    timer.cpu = null;
                    timer.state.store(.Stopped, .release);

                    cpu.lock.release_no_ipl();
                    timer.hdr.lock.release_no_ipl();
                    return;
                }

                cpu.lock.release_no_ipl();
                timer.hdr.lock.release_no_ipl();
            },
        }
    }
}

/// Compare two timers.
pub fn cmp_timer(
    a: *rtl.pairing_heap.Node,
    b_: *rtl.pairing_heap.Node,
) std.math.Order {
    const timer_a: *Timer = @fieldParentPtr("node", a);
    const timer_b: *Timer = @fieldParentPtr("node", b_);

    return std.math.order(timer_a.deadline.value, timer_b.deadline.value);
}

/// Called by the platform on a clock interrupt.
pub fn clock() void {
    ke.dpc.enqueue(&percpu.local().dpc, null);
    // Check for overflows.
    // This is fine to call a lot, as the function only gets expensive
    // (i.e seqlock store) when an overflow actually happens.
    kep.time.update_overflow();
}

// Called in a DPC when a timer has expired.
fn handle_expiry(_: *ke.Dpc, _: ?*anyopaque) void {
    assert(kep.ipl.current() == .Dispatch);
    const cpu = percpu.local();

    while (true) {
        const curtime = ke.time.read_time();

        cpu.lock.acquire_no_ipl();

        // Get the timer that expires the soonest.
        const timer_node = cpu.timers.root orelse {
            cpu.lock.release_no_ipl();
            return;
        };

        const timer: *Timer = @fieldParentPtr("node", timer_node);

        // If the timer expires more than 1ms in the future, consider it not
        // yet due. Sub-millisecond differences are close enough to expire
        // immediately.
        if (timer.deadline.value > curtime.value and
            timer.deadline.value - curtime.value > std.time.ns_per_ms)
        {
            const now = ke.time.read_time();
            if (timer.deadline.value > now.value and
                timer.deadline.value - now.value > std.time.ns_per_ms)
            {
                pl.arm_timer(rtl.Duration.ns(timer.deadline.value - now.value));
                cpu.lock.release_no_ipl();
                return;
            }
        }

        assert(timer.state.load(.monotonic) == .Pending);
        timer.state.store(.Running, .monotonic);

        _ = cpu.timers.pop();
        cpu.lock.release_no_ipl();

        const maybe_dpc = timer.dpc;

        timer.hdr.lock.acquire_no_ipl();

        // Set signaled.
        timer.hdr.signaled = 1;
        timer.cpu = null;

        // Wake whomever was waiting on the timer.
        kep.wait.satisfy_wait(&timer.hdr);
        if (maybe_dpc) |dpc| ke.dpc.enqueue(dpc, null);

        timer.state.store(.Stopped, .release);
        timer.hdr.lock.release_no_ipl();
    }
}
