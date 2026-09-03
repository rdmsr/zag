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

    pub const Context = extern struct {
        /// Implementation-dependent context.
        impl: ki.impl.ThreadContext,

        stack_top: usize,

        pub fn init_with_stack(
            stack: r.VAddr,
        ) Context {
            return .{
                .impl = .init_with_stack(
                    stack,
                ),
                .stack_top = stack,
            };
        }

        pub fn reset(
            self: *@This(),
            stack_top: r.VAddr,
            entry: *const fn (?*anyopaque) void,
            arg: ?*anyopaque,
        ) void {
            self.stack_top = stack_top;
            _ = self.impl.reset(stack_top, entry, arg);
        }
    };
    context: Context,
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
    /// PELT load average,
    avg: ki.sched.Average,
    /// Accounting statistics.
    acct: ki.sched.Accounting,
    /// Set whenever the thread is switching off its stack.
    /// This is used to avoid taking thread next lock to wait for switch off
    /// to complete.
    switching: std.atomic.Value(bool),
    smr_sections: rtl.List,
    hard_affinity: ke.CpuMask,
    continuation: ?Continuation,

    const InitOpts = struct {
        /// Entry point of the thread.
        entry: ke.Continuation,
        /// Top of the stack for the thread.
        stack: r.VAddr,
        /// Turnstile associated with the thread.
        turnstile: *ki.turnstile.Turnstile,
        /// Thread's priority.
        priority: Priority,
    };

    /// Initialize a thread.
    pub fn init(
        thread: *Thread,
        opts: InitOpts,
    ) void {
        thread.* = .{
            .context = .init_with_stack(opts.stack),
            .lock = .init(),
            .nice = 0,
            .priority = @intFromEnum(opts.priority),
            .base_priority = @intFromEnum(opts.priority),
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
            .turnstile = opts.turnstile,
            .turnstile_waiter = null,
            .turnstiles_owned = undefined,
            .waiting_on = null,
            .queue = null,
            .queue_item = null,
            .continuation = opts.entry,
            .switching = .init(false),
            .avg = .{},
            .acct = .{},
            .smr_sections = undefined,
            .hard_affinity = .init(true),
        };

        thread.turnstiles_owned.init();
        thread.timer.init();
        thread.smr_sections.init();

        if (opts.stack != 0) {
            thread.context.reset(
                opts.stack,
                call_continuation,
                thread,
            );
        }
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

    pub fn can_relinquish_stack(self: *Thread) bool {
        const state = self.state.load(.monotonic);

        // Stack donation for realtime threads is disabled, unless they are
        // exiting.
        return self.base_priority_class() != .Realtime or
            state == .Zombie or
            state == .Terminated;
    }

    pub fn can_receive_stack(self: *Thread) bool {
        // Realtime threads shouldn't donate their stack, so they can't receive
        // them.
        return self.base_priority_class() != .Realtime;
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
    ki.sched.yield_locked(Continuation.dummy);
}

/// Return the currently running thread.
pub fn current() *ke.Thread {
    return ki.sched.percpu.local().current_thread.?;
}

// -- Stack allocation and continuations ---------------------------------------
pub const Continuation = struct {
    func: *const fn (_: ?*anyopaque) void,
    arg: ?*anyopaque,

    pub const dummy: Continuation = .{
        .func = dummy_fn,
        .arg = null,
    };

    fn dummy_fn(_: ?*anyopaque) void {}
};

const Depot = struct {
    stacks: ?*Stack = null,
    count: u32 = 0,
    min: u32 = 0,
    wma: u32 = 0,
};

pub const Stack = struct {
    next: ?*Stack,
    prev: ?*Stack,
};

const Cpu = struct {
    stack_alloc_dpc: ke.Dpc,
    depot: Depot,
};

/// Number of excess stacks allowed in the global stack depot before trimming.
/// Note that this is in addition to the global minimum of `ncpus` stacks.
/// Keep this low for minimal memory overhead, but potentially increased latency.
const excess_stacks = ke.Tunable(u32, 1, "ke.thread.excess_stacks");

var global_depot_lock: ke.SpinLock = .init();
var global_depot: Depot = .{};

const percpu = ke.CpuLocal(Cpu, undefined);
const percpu_count_max = 2;

const wma_unit = 256;

pub var thread_stack_queue: rtl.HandoffList = .init(stack_activation);

inline fn wma_mix(old: u32, new: u32) u32 {
    // Keep 75% of old sample and 25% of new.
    return (3 * old + new * wma_unit) / 4;
}

fn init_cpu() linksection(r.init) void {
    const cpu = percpu.local();
    cpu.* = .{
        .stack_alloc_dpc = .init(stack_alloc_handler),
        .depot = .{},
    };
}

comptime {
    _ = r.percpu_init_set.insert(&init_cpu);
}

pub fn call_continuation(ptr: ?*anyopaque) noreturn {
    const td: *ke.Thread = @ptrCast(@alignCast(ptr));
    std.debug.assert(td.continuation != null);

    const cont = td.continuation.?;
    td.continuation = null;

    ki.impl.call_continuation(&td.context, cont);
}

/// Try to get a stack from the stack cache.
pub fn stack_cache_pop() ?usize {
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    const cpu = &percpu.local().depot;

    // Try to get a stack from the per-cpu depot.
    if (cpu.count != 0) {
        const entry = cpu.stacks.?;
        cpu.stacks = entry.next;
        cpu.count -= 1;
        return @intFromPtr(entry) + @sizeOf(ke.Stack);
    }

    // Otherwise, try and get it from the global depot.
    global_depot_lock.acquire_no_ipl();
    defer global_depot_lock.release_no_ipl();

    if (global_depot.count != 0) {
        const entry = global_depot.stacks.?;
        global_depot.stacks = entry.next;
        global_depot.count -= 1;
        global_depot.min = @min(global_depot.min, global_depot.count);
        return @intFromPtr(entry) + @sizeOf(ke.Stack);
    }

    return null;
}

/// Free a stack back to the depot.
pub fn stack_cache_free(stack: usize) void {
    const entry: *Stack = @ptrFromInt(stack - @sizeOf(Stack));

    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    const cpu = &percpu.local().depot;

    if (cpu.count < percpu_count_max) {
        entry.next = cpu.stacks;
        cpu.stacks = entry;
        cpu.count += 1;
        return;
    }

    global_depot_lock.acquire_no_ipl();
    defer global_depot_lock.release_no_ipl();

    entry.next = global_depot.stacks;
    global_depot.stacks = entry;
    global_depot.count += 1;
}

/// Periodic updates to the stack depot.
/// Keeps track of the number of alloc / free that happened
/// in the last time span and reaps the excess stacks, if necessary.
pub fn stack_cache_update() ?*Stack {
    const ipl = global_depot_lock.acquire();
    defer global_depot_lock.release(ipl);

    global_depot.wma = wma_mix(global_depot.wma, global_depot.min);

    var excess = @min(
        global_depot.min * wma_unit,
        global_depot.wma,
    ) / wma_unit;

    global_depot.min = global_depot.count;

    // If we have more than `excess_stacks` sitting unused, then trim.
    // Ensure there are still `ncpus` stacks sitting in the depot.
    if (excess > excess_stacks.load()) {
        std.debug.assert(global_depot.count >= excess);

        // We want every CPU to have at least one stack sitting in the depot.
        const floor: u32 = @truncate(ke.ncpus);
        excess = @min(excess, global_depot.count -| floor);

        const new_count = global_depot.count - excess;
        global_depot.min = new_count;

        if (excess == 0) return null;

        // Splice the list from the tail to get the coldest stacks.
        var prev = global_depot.stacks.?;
        for (1..new_count) |_| prev = prev.next.?;

        const head = prev.next;
        prev.next = null;

        global_depot.count = new_count;
        global_depot.wma -= excess * wma_unit;

        return head;
    }

    return null;
}

pub fn stacks_count() usize {
    var ret: usize = 0;

    for (0..ke.ncpus) |i| {
        const cpu = percpu.remote(@truncate(i));
        ret += @atomicLoad(u32, &cpu.depot.count, .monotonic);
    }

    const ipl = global_depot_lock.acquire();
    ret += global_depot.count;
    global_depot_lock.release(ipl);

    return ret;
}

fn stack_activation(_: ?*rtl.HandoffList) void {
    const cpu = percpu.local();
    ke.dpc.enqueue(&cpu.stack_alloc_dpc, null);
}

fn stack_alloc_handler(_: *ke.Dpc, _: ?*anyopaque) void {
    r.ps.private.thread.stack_activation();
}
