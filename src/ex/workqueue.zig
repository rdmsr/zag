//! Work queues and work items.
//! Work queues are used to enqueue work to be done in a thread context asynchronously.
//! There are three global work queues for each priority:
//! - High
//! - Normal
//! - Low
//! High and Normal work queues are per-cpu, and there is one global queue and thread for low-priority work.
//! Each CPU has one worker thread, until that thread blocks, then another thread is spawned to pick up work on it.
const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const ps = r.ps;
const mm = r.mm;

/// Represents a single work item.
pub const WorkItem = struct {
    func: *const fn (arg: ?*anyopaque) void,
    arg: ?*anyopaque,
    link: rtl.List.Entry,
    enqueued: std.atomic.Value(bool),
    priority: Priority,

    pub const Priority = enum {
        /// Low priority background work.
        Low,
        /// Normal priority work.
        Normal,
        /// High priority work.
        High,

        pub fn to_sched_prio(prio: Priority) u8 {
            return switch (prio) {
                .Low => ke.Thread.Priority.low_batch,
                .Normal => ke.Thread.Priority.high_batch,
                .High => ke.Thread.Priority.low_realtime,
            };
        }
    };

    pub fn init(self: *WorkItem, priority: Priority, func: *const fn (arg: ?*anyopaque) void, arg: ?*anyopaque) void {
        self.* = .{
            .func = func,
            .arg = arg,
            .link = undefined,
            .enqueued = .init(false),
            .priority = priority,
        };
    }
};

/// Represents a thread worker pool and its queue.
const Pool = struct {
    const Worker = struct {
        link: rtl.List.Entry,
        td: *ps.Thread,
    };
    /// The enqueued items.
    queue: ke.Queue,
    /// Priority of the pool.
    prio: WorkItem.Priority,
    /// CPU this pool is on.
    cpu: ?u32,
    lock: ke.SpinLock,

    pub fn init(self: *Pool, prio: WorkItem.Priority, cpu: ?u32) !void {
        self.queue.init(1);
        self.prio = prio;
        self.cpu = cpu;
        self.lock = .init();

        // TODO: dynamic worker pool.
        // We don't support thread exits yet, so add that first.
        // Do linux-style where worker threads themselves spawn new threads.
        const how_many: usize = if (prio == .Low) 4 else 2;

        for (0..how_many) |_| {
            var td = try ps.thread.create_kernel(
                WorkItem.Priority.to_sched_prio(self.prio),
                work_loop,
                self,
            );

            if (cpu != null) {
                td.kern.last_cpu = cpu;
                td.kern.pinned = true;
            }

            ke.sched.enqueue(&td.kern);
        }
    }
};

/// Per-CPU work data.
const PerCpu = struct {
    /// High-priority work queue.
    high: Pool,
    /// Normal-priority work queue.
    normal: Pool,
};

const percpu = ke.CpuLocal(PerCpu, undefined);

/// Low-priority work queue.
var low: Pool = undefined;

fn work_loop(p: ?*anyopaque) void {
    const pool: *Pool = @ptrCast(@alignCast(p));

    while (true) {
        const item = pool.queue.remove();
        const work: *WorkItem = @fieldParentPtr("link", item);

        work.enqueued.store(false, .release);
        work.func(work.arg);
    }
}

/// Enqueue a work item to be executed eventually.
pub fn enqueue(item: *WorkItem) void {
    // Ensure CPU stays consistent.
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    if (item.enqueued.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
        return;
    }

    var pool: *Pool = undefined;

    switch (item.priority) {
        .High => {
            pool = &percpu.local().high;
        },
        .Normal => {
            pool = &percpu.local().normal;
        },
        .Low => {
            pool = &low;
        },
    }

    pool.queue.insert(&item.link, .Tail);
}

/// Initialize the workqueue subsystem.
pub fn init() !void {
    for (0..ke.ncpus) |cpu| {
        const c = percpu.remote(@intCast(cpu));

        try c.high.init(.High, @intCast(cpu));
        try c.normal.init(.Normal, @intCast(cpu));
    }

    try low.init(.Low, null);
}
