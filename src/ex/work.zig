//! Worker pools and work items.
//!
//! Work items are used to enqueue work to be done in a thread context asynchronously.
//! There are three worker priorities:
//! - High
//! - Normal
//! - Low
//! High and Normal worker pools are per-cpu, and there is one global worker pool
//! for low-priority work.
//!
//! Each CPU worker pool comprises of at least 2 threads, and the low pool
//! has 4 threads by default. An additional thread will get spawned by the
//! pool manager thread if a queue has a backlog, up to 4 additional dynamic threads
//! (tunable) per pool.

const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const ps = r.ps;
const mm = r.mm;

/// Maximum number of additional threads created per pool.
const max_dynamic_threads = ke.Tunable(u8, 4, "ex.work.max_dynamic");

var pool_manager_event: ke.Event = undefined;

fn min_threads_for_prio(prio: WorkItem.Priority) usize {
    return if (prio == .Low) 4 else 2;
}

fn max_threads_for_prio(prio: WorkItem.Priority) usize {
    return min_threads_for_prio(prio) + max_dynamic_threads.load();
}

/// Represents a single work item.
pub const WorkItem = struct {
    func: *const fn (arg: ?*anyopaque) void,
    arg: ?*anyopaque,
    link: rtl.List.Entry,
    enqueued: std.atomic.Value(bool),
    priority: Priority,
    dpc: ke.Dpc,
    timer: ke.Timer,

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
            .dpc = .init(work_dpc),
            .timer = undefined,
        };

        self.timer.init();
    }
};

const Context = rtl.TaggedPtr(Pool);

/// Represents a thread worker pool and its queue.
const Pool = struct {
    /// The enqueued items.
    queue: ke.Queue,
    /// Priority of the pool.
    prio: WorkItem.Priority,
    /// CPU this pool is on.
    cpu: ?u32,
    total_threads: std.atomic.Value(usize),

    fn init(self: *Pool, prio: WorkItem.Priority, cpu: ?u32) !void {
        self.queue.init(if (prio == .Low) ke.ncpus else 1);
        self.prio = prio;
        self.cpu = cpu;

        const how_many = min_threads_for_prio(prio);

        self.total_threads = .init(how_many);

        for (0..how_many) |_| {
            const ctx: Context = .init(self, 0);

            var td = try ps.thread.create_kernel(
                WorkItem.Priority.to_sched_prio(self.prio),
                work_loop,
                @ptrFromInt(ctx.value),
            );

            if (cpu != null) {
                td.kern.last_cpu = cpu;
                td.kern.pinned = true;
            }

            ke.sched.enqueue(&td.kern);
        }
    }

    /// Return whether or not a new worker thread should be spawned on this pool.
    fn should_grow(self: *Pool) bool {
        // NOTE: lockless racy check whether or not the queue is empty
        // and its active count.
        // This is fine as this is best effort anyway and is a heuristic.
        const is_empty = @atomicLoad(
            *rtl.List.Entry,
            &self.queue.items.head.next,
            .monotonic,
        ) == &self.queue.items.head;

        const active = @atomicLoad(usize, &self.queue.active, .monotonic);
        const threads = self.total_threads.load(.monotonic);

        if (threads < max_threads_for_prio(self.prio) and !is_empty and active < self.queue.max_active) {
            // We have room to grow, the list still has items and
            // not enough runnable threads are present, create an
            // additional thread to ease the backlog.
            return true;
        }

        return false;
    }

    /// Spawn a dynamic worker thread on this pool.
    fn grow(self: *Pool, cpu: ?u32) !void {
        if (self.total_threads.load(.monotonic) >= max_threads_for_prio(self.prio))
            return;

        _ = self.total_threads.fetchAdd(1, .monotonic);

        const ctx: Context = .init(self, 1);

        var td = try ps.thread.create_kernel(
            WorkItem.Priority.to_sched_prio(self.prio),
            work_loop,
            @ptrFromInt(ctx.value),
        );

        if (cpu != null) {
            td.kern.last_cpu = cpu;
            td.kern.pinned = true;
        }

        ke.sched.enqueue(&td.kern);
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
    const ctx: Context = .{ .value = @intFromPtr(p) };
    const dynamic = ctx.get_tag() == 1;

    while (true) {
        const timeout: ?r.Nanoseconds = if (dynamic) std.time.ns_per_s * 5 else null;
        const item = ctx.get_ptr().queue.remove(timeout) catch {
            _ = ctx.get_ptr().total_threads.fetchSub(1, .monotonic);

            // We haven't had work in a while, exit.
            ps.thread.exit();
            return;
        };

        const work: *WorkItem = @fieldParentPtr("link", item);

        work.enqueued.store(false, .release);
        work.func(work.arg);
    }
}

/// Called when a work timer expires.
fn work_dpc(dpc: *ke.Dpc, _: ?*anyopaque) void {
    const item: *WorkItem = @fieldParentPtr("dpc", dpc);
    enqueue(item);
}

/// Enqueue a work item in `time`.
pub fn enqueue_in(item: *WorkItem, time: r.Nanoseconds) void {
    ke.timer.set(&item.timer, time, &item.dpc);
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

    if (pool.should_grow()) {
        pool_manager_event.signal();
    }
}

fn pool_manager(_: ?*anyopaque) void {
    while (true) {
        _ = ke.wait.wait_one(&pool_manager_event.hdr, null) catch unreachable;

        // We have been signaled, go through every pool and grow it if needed.
        // Failure to grow is ignored, it is only a latency problem and should be fixed
        // eventually as memory is freed.
        for (0..ke.ncpus) |i| {
            const cpu: u32 = @intCast(i);
            const c = percpu.remote(cpu);

            if (c.high.should_grow()) {
                _ = c.high.grow(cpu) catch {};
            }

            if (c.normal.should_grow()) {
                _ = c.normal.grow(cpu) catch {};
            }
        }

        if (low.should_grow()) {
            _ = low.grow(null) catch {};
        }
    }
}

/// Initialize the work subsystem.
pub fn init() !void {
    pool_manager_event.init(.Synchronization);

    for (0..ke.ncpus) |cpu| {
        const c = percpu.remote(@intCast(cpu));

        try c.high.init(.High, @intCast(cpu));
        try c.normal.init(.Normal, @intCast(cpu));
    }

    try low.init(.Low, null);

    var td = ps.thread.create_kernel(
        ke.Thread.Priority.default,
        pool_manager,
        null,
    ) catch @panic("Failed to create pool manager");

    ke.sched.enqueue(&td.kern);
}
