const std = @import("std");
const r = @import("root");
const rtl = @import("rtl");

const ke = r.ke;
const ki = ke.private;

/// Structure representing a kernel thread.
pub const Thread = struct {
    /// Thread priority classes.
    /// Realtime: Highest priority, aggressively scheduled.
    /// Batch: Normal priority.
    /// Idle: For idle and background threads.
    pub const Priority = struct {
        pub const Class = enum(u8) {
            Realtime,
            Batch,
            Idle,
        };

        pub const idle = 0;

        /// Batch threads have priorities 1-23
        pub const low_batch = 1;
        pub const high_batch = 23;
        pub const batch_range = high_batch - low_batch + 1;

        /// Realtime threads have priorities 40-63
        pub const low_realtime = 40;
        pub const max = 63;

        /// In the mid-range of batch threads
        pub const default = 10;

        /// Interactive threads have priorities 24-39
        pub const low_interactive = 24;
        pub const high_interactive = 39;

        pub fn class_from_prio(prio: u8) Class {
            if (prio >= low_realtime and prio <= max) return .Realtime;
            if (prio >= low_batch and prio < low_realtime) return .Batch;
            if (prio == idle) return .Idle;

            unreachable;
        }
    };

    /// Thread state.
    pub const State = enum(u8) {
        /// The thread is ready to run.
        Ready,
        /// The thread is currently running.
        Running,
        /// The thread was selected to run.
        Selected,
        /// The thread is currently sleeping.
        Blocked,
        /// The thread has exited and is waiting to be reaped.
        Zombie,
        /// The thread has exited.
        Terminated,
    };
    /// Implementation-dependent context.
    context: ki.impl.ThreadContext,
    /// Thread lock.
    lock: ke.SpinLock,
    /// Niceness value.
    nice: i8,
    /// Effective priority value of the thread: `max(base_priority, inherited_prio)`.
    priority: u8,
    /// Base priority value of the thread.
    base_priority: u8,
    /// Priority inherited via priority donation.
    inherited_prio: u8,
    /// When the thread started sleeping.
    sleep_start: u64,
    /// Ticks spent voluntarily sleeping recently.
    sleep_time: u64,
    /// Ticks spent running recently.
    run_time: u64,
    /// Whether the thread is pinned to this CPU.
    /// If it is pinned, then it can't be moved across another CPU.
    pinned: bool,
    /// Current state of the thread.
    state: std.atomic.Value(State),
    /// Linkage into a scheduler run queue.
    runq_link: rtl.List.Entry,
    /// Last CPU this thread ran on.
    last_cpu: ?u32,
    /// CPU this thread is enqueued on.
    cpu: ?u32,
    /// Run queue this thread is in
    runq: ?*ki.sched.RunQueue,
    /// Index into the run queue this thread is currently in.
    /// Only valid when `runq` is non-null.
    runq_idx: u8,
    /// Current wait status.
    wait_status: std.atomic.Value(ki.wait.Status),
    waitblocks: [4]ki.wait.WaitBlock,
    /// Timer used for timeouts.
    timer: ke.Timer,
    /// Turnstile.
    turnstile: *ki.turnstile.Turnstile,
    turnstile_waiter: ?*ki.turnstile.Waiter,
    turnstiles_owned: rtl.List,
    /// Object this thread is currently blocked on, or null.
    waiting_on: ?*anyopaque,
    /// Queue this thread is associated with.
    queue: ?*ke.Queue,
    queue_item: ?*rtl.List.Entry,
    /// Base of the stack.
    stack: r.VAddr,

    /// Initialize a thread.
    /// - `stack`: Address of the **base** of the stack on which the initial context for the thread is built
    /// - `stack_size`: Size of the stack
    /// - `prio`: Base priority of the thread
    /// - `entry`: Entry point of the thread
    /// - `arg`: Extraneous argument to be passed to `entry`
    pub fn init(thread: *Thread, stack: r.VAddr, stack_size: usize, prio: u8, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
        thread.* = .{
            .context = .init(stack, stack_size, entry, arg),
            .lock = .init(),
            .nice = 0,
            .priority = prio,
            .base_priority = prio,
            .inherited_prio = 0,
            .sleep_start = 0,
            .sleep_time = 0,
            .run_time = 0,
            .pinned = false,
            .state = .init(.Ready),
            .runq_link = .{},
            .last_cpu = null,
            .cpu = null,
            .runq = null,
            .runq_idx = 0,
            .wait_status = .init(.Satisfied),
            .waitblocks = undefined,
            .timer = undefined,
            .turnstile = undefined,
            .turnstile_waiter = null,
            .turnstiles_owned = undefined,
            .waiting_on = null,
            .queue = null,
            .queue_item = null,
            .stack = stack,
        };

        thread.turnstiles_owned.init();

        thread.timer.init();
    }

    pub fn priority_class(self: *Thread) Priority.Class {
        return Priority.class_from_prio(self.priority);
    }

    /// Class of the thread's *base* priority, ignoring any inherited boost.
    pub fn base_priority_class(self: *Thread) Priority.Class {
        return Priority.class_from_prio(self.base_priority);
    }

    /// The priority the thread should run at.
    pub fn effective_priority(self: *Thread) u8 {
        return @max(self.base_priority, self.inherited_prio);
    }

    pub fn is_interactive(self: *Thread) bool {
        return self.priority >= Priority.low_interactive and self.priority <= Priority.high_interactive;
    }
};

/// HandoffList of threads waiting to be reaped.
/// This is managed by the process subsystem.
pub var reaper_list: rtl.HandoffList = undefined;

/// Terminate the currently running thread.
/// This does not return.
pub fn exit() void {
    _ = ke.ipl.raise(.Dispatch);
    const curtd = current();

    curtd.lock.acquire_no_ipl();
    curtd.state.store(.Zombie, .monotonic);

    // Reuse the runq linkage to put on reaper list.
    reaper_list.insert(@ptrCast(&curtd.runq_link.next));

    ki.sched.yield_locked();
}

/// Return the currently running thread.
pub fn current() *ke.Thread {
    return ki.sched.percpu.local().current_thread.?;
}
