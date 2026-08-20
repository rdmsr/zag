const std = @import("std");
const r = @import("root");
const rtl = @import("rtl");

const ke = r.ke;
const ki = ke.private;

pub const Priority = enum(u8) {
    const Self = @This();

    /// Reserved for the idle thread.
    IdleThread = 0,
    /// Background kernel work.
    Idle = 1,
    /// Low priority CPU-bound work
    LowBatch = 2,
    /// High priority CPU-bound work
    HighBatch = 137,
    /// Low priority interactive work.
    LowInteractive = 138,
    /// High priority interactive work.
    HighInteractive = 223,
    /// The default thread priority.
    Default = 117,
    /// Low priority real-time work.
    LowRealtime = 224,
    /// Mid priority real-time work.
    MidRealtime = 239,
    /// High priority real-time work.
    HighRealtime = 255,
    _,

    pub const Class = enum(u8) {
        Realtime,
        Timeshare,
        Idle,
    };

    pub const max = 255;
    pub const nice_max = 20;

    // The low and top 20 priorities from the batch range are reserved
    // for nice.
    pub const cpu_range = @intFromEnum(Self.HighBatch) - (nice_max * 2) - 1;

    pub fn class_from_prio(prio: u8) Class {
        if (prio >= @intFromEnum(Self.LowRealtime) and
            prio <= @intFromEnum(Self.HighRealtime))
            return .Realtime;

        if (prio >= @intFromEnum(Self.LowBatch) and
            prio < @intFromEnum(Self.LowRealtime))
            return .Timeshare;

        if (prio <= @intFromEnum(Self.Idle))
            return .Idle;

        unreachable;
    }
};

/// Structure representing a kernel thread.
pub const Thread = struct {
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
    /// Reason for the wait, if any.
    wait_reason: ?[]const u8,
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
    /// PELT load average,
    avg: ki.sched.Average,
    /// Accounting statistics.
    acct: ki.sched.Accounting,
    /// Set whenever the thread is switching off its stack.
    /// This is used to avoid taking thread next lock to wait for switch off
    /// to complete.
    switching: std.atomic.Value(bool),
    smr_sections: rtl.List,

    /// Initialize a thread.
    /// - `stack`: Address of the base of the stack used by the thread.
    /// - `stack_size`: Size of the stack
    /// - `prio`: Base priority of the thread
    /// - `entry`: Entry point of the thread
    /// - `arg`: Extraneous argument to be passed to `entry`
    pub fn init(
        thread: *Thread,
        stack: r.VAddr,
        stack_size: usize,
        prio: Priority,
        entry: *const fn (?*anyopaque) void,
        arg: ?*anyopaque,
    ) void {
        thread.* = .{
            .context = .init(
                stack,
                stack_size,
                entry,
                arg,
            ),
            .lock = .init(),
            .nice = 0,
            .priority = @intFromEnum(prio),
            .base_priority = @intFromEnum(prio),
            .inherited_prio = 0,
            .pinned = false,
            .state = .init(.Ready),
            .runq_link = .{},
            .last_cpu = null,
            .cpu = null,
            .runq = null,
            .runq_idx = 0,
            .wait_status = .init(.Satisfied),
            .waitblocks = undefined,
            .wait_reason = null,
            .timer = undefined,
            .turnstile = undefined,
            .turnstile_waiter = null,
            .turnstiles_owned = undefined,
            .waiting_on = null,
            .queue = null,
            .queue_item = null,
            .stack = stack,
            .switching = .init(false),
            .avg = .{},
            .acct = .{},
            .smr_sections = undefined,
        };

        thread.turnstiles_owned.init();
        thread.timer.init();
        thread.smr_sections.init();
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
        return self.priority >= @intFromEnum(Priority.LowInteractive) and
            self.priority <= @intFromEnum(Priority.HighInteractive);
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

    ki.sched.detach_load_avg(ki.sched.percpu.local(), curtd);
    ki.sched.yield_locked();
}

/// Return the currently running thread.
pub fn current() *ke.Thread {
    return ki.sched.percpu.local().current_thread.?;
}
