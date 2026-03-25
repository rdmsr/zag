const std = @import("std");
const b = @import("base");
const rtl = @import("rtl");

const ke = b.ke;
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
        pub const low_batch = 1;
        pub const high_batch = 32;
        pub const batch_range = high_batch - low_batch + 1;
        pub const realtime = 33;
        pub const max = 63;
        /// In the mid-range of batch threads
        pub const default = 16;
        /// Interactive threads have a slightly higher priority
        pub const interactive = 20;

        pub fn class_from_prio(prio: u8) Class {
            if (prio >= realtime and prio <= max) return .Realtime;
            if (prio >= low_batch and prio <= high_batch) return .Batch;
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
    /// Priority value of the thread.
    priority: u8,
    /// Priority class of the thread.
    priority_class: Priority.Class,
    /// When the thread started sleeping.
    sleep_start: u64,
    /// Ticks spent voluntarily sleeping recently.
    sleep_time: u64,
    /// Ticks spent running recently.
    run_time: u64,
    /// Whether the thread is interactive or not.
    interactive: bool,
    /// Whether the thread is pinned to this CPU.
    /// If it is pinned, then it can't be moved across another CPU.
    pinned: bool,
    /// Current state of the thread.
    state: State,
    /// Linkage into a scheduler run queue.
    runq_link: rtl.List.Entry,
    /// Last CPU this thread ran on.
    last_cpu: ?*ke.Cpu,

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

    /// Initialize a thread.
    /// - `stack`: Address of the **base** of the stack on which the initial context for the thread is built
    /// - `stack_size`: Size of the stack
    /// - `entry`: Entry point of the thread
    /// - `arg`: Extraneous argument to be passed to `entry`
    pub fn init(thread: *Thread, stack: b.VAddr, stack_size: usize, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) void {
        thread.* = .{
            .context = .init(stack, stack_size, entry, arg),
            .lock = .init(),
            .nice = 0,
            .priority = Thread.Priority.default,
            .priority_class = Thread.Priority.Class.Batch,
            .sleep_start = 0,
            .sleep_time = 0,
            .run_time = 0,
            .interactive = false,
            .pinned = false,
            .state = .Ready,
            .runq_link = .{},
            .last_cpu = null,
            .runq = null,
            .runq_idx = 0,
            .wait_status = .init(.InProgress),
            .waitblocks = undefined,
            .timer = undefined,
        };

        thread.timer.init();
    }
};

comptime {
    if (!@hasDecl(ki.impl, "ThreadContext")) @compileError("impl must provide ThreadContext");
    if (!@hasDecl(ki.impl.ThreadContext, "init")) @compileError("ThreadContext must have init()");
}
