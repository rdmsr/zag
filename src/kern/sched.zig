//! Kernel scheduler inspired by FreeBSD's ULE scheduler.
//!
//! ## Overview
//! -----------
//! Threads are divided into three priority classes:
//!
//! - `Realtime`: Always scheduled before batch and idle threads.
//!   Picked from `realtime_runq` in priority order.
//!   Interactive batch threads are promoted into this queue.
//! - `Batch`: Scheduled via a circular calendar queue that rotates
//!   on every tick, ensuring all threads get CPU time proportional
//!   to their priority.
//! - `Idle`: Only scheduled when both realtime and batch queues are empty.
//!
//! ## Interactivity Scoring
//! ------------------------
//!
//! Each batch thread is assigned an interactivity score based on the
//! ratio of its recent sleep time to its recent CPU time:
//!
//! - If `sleep_time > run_time`: score = `run_time / (sleep_time / scaling_factor)`
//!   — heavily sleeping threads score low (more interactive).
//! - If `run_time > sleep_time`: score = `scaling_factor * 2 - (sleep_time / (run_time / scaling_factor))`
//!   — CPU-bound threads score high (less interactive).
//! - Niceness is added to the score, making low-nice threads easier to
//!   qualify as interactive.
//!
//! Threads scoring below `interactivity_threshold` are considered
//! interactive and promoted to the realtime queue with a priority derived
//! from their score. This lets I/O-bound threads respond quickly without
//! being assigned a realtime priority.
//!
//! To prevent history from dominating forever, `sleep_time` and `run_time`
//! are decayed periodically by `sched_clamp_time`:
//! - Values are halved when their sum exceeds 120% of the 5-second cap.
//! - Values are reduced by 20% when the sum exceeds 5 seconds.
//! - Values are reset to (max, 1) when the sum exceeds 10 seconds.
//!
//! ## Calendar Queue
//! -----------------
//!
//! The calendar queue is a circular array of `runqueues_n` (64) lists.
//! It comprises of two indices:
//!
//! - `runidx`: The queue currently being drained by the scheduler.
//! - `insidx`: The queue where newly inserted threads land.
//!   Always one slot ahead of `runidx` so fresh threads are never
//!   picked in the same tick they were enqueued.
//!
//! Threads are inserted at `(insidx + prio_high_batch - thread.priority) % runqueues_n`,
//! placing lower-priority threads further ahead in the rotation so
//! they run less frequently than higher-priority ones.
//!
//! On every tick (10ms), `insidx` advances by one, giving all threads
//! the chance to run over time regardless of priority.
//!
//! ## Preemption
//! -------------
//!
//! Timeshared (batch) threads do not preempt each other by default.
//! Interactive threads may still preempt non-interactive batch threads.
//! Realtime threads always preempt batch and idle threads.
//!
//! Remote preemption is done lock-free by reading atomically a
//! `current_thread_prio` field that stores the running thread's priority.
//!
//! ## Load Balancing
//! -----------------
//!
//! Three mechanisms keep load distributed across CPUs:
//!
//! 1. When a thread is enqueued, its CPU might be changed if it is not pinned.
//! 2. Work stealing: When a CPU goes idle, it immediately attempts to
//!   steal a thread from the most loaded CPU.
//! 3. Periodic balancing: Every ~1 second (randomized with an LCG to
//!   avoid phase-locking with periodic threads), CPU0 moves
//!   threads from the most loaded CPU to the least loaded one.
//!
//! ## CPU Selection
//! ----------------
//!
//! CPU selection is done on various metrics, but mostly relies on the CPU load
//! and its load average. The load represents the number of threads currently sitting
//! in its runqueue, while the load average uses per-entity load tracking (PELT)
//! to broadly measure CPU utilization, see comment below.
//! The load average is the only metric relied upon by periodic load balancing,
//! since it represents the broader history of a CPU. For other forms of balancing,
//! the load is preferred as to prioritize latency (i.e. you want to run a thread ASAP).
//!
//! See `sched_ule.c` in FreeBSD for the original implementation this is based on.

const std = @import("std");
const rtl = @import("rtl");
const config = @import("config");
const r = @import("root");
const ke = r.ke;
const ki = ke.private;

const runqueues_n = 64;
const interactivity_threshold = 30;
const scaling_factor = 50;
const preempt_threshold = ke.Thread.Priority.low_realtime;
const balance_interval = @as(u64, config.sched_balance_interval);
const steal_threshold = 1;

// Per-entity load tracking (PELT)
// -------------------------------
// Comes from the Linux feature of the same name.
//
// Each thread carries a decaying exponential weighted moving average (EWMA)
// of the time it has spent runnable (running or in a queue). Each CPU maintains
// the sum of its threads' values, which is used in load balancing decisions to
// estimate the *actual* load of a CPU (and not just its thread count). Each value
// is updated using periods of 1024us (~1ms) with a half-life of 32ms, i.e y^32 = 0.5.
// Math goes more in depth in comments below.
const pelt_scale = 1024;
const pelt_decay = 32;
const pelt_halflife = pelt_scale * pelt_decay;

//                       inf
// From load_avg_max = p Sum y^n
//                       n=0
// We can derive, with a half-life of 32:
//   inf        31
// p Sum y^n = (Sum y^k) * (1 + 1/2 + 1/4 + ...)
//   n=0        k=0
//
//                                  31
// Which yields: load_avg_max = 2*p Sum y^n
//                                  n=0
// We can simplify this as p / (1 - y), so 1024 / (1 - table[1]),
// keeping in mind integer math, we use 1023 as our floor and calculate:
// floor((2^32 * 1023) / (2^32 - table[1])) + 1 as our value, yielding 47742.
pub const pelt_load_avg_max = 47742;

// pelt_inv_table[k] = floor(2^32 * 2^(-k/pelt_decay))
// NOTE: Linux uses 2^32 - 1 as base but this practically yields the same values.
const pelt_inv_table: [pelt_decay]u32 = .{
    0xffffffff, 0xfa83b2db, 0xf5257d15, 0xefe4b99b,
    0xeac0c6e7, 0xe5b906e7, 0xe0ccdeec, 0xdbfbb797,
    0xd744fcca, 0xd2a81d91, 0xce248c15, 0xc9b9bd86,
    0xc5672a11, 0xc12c4cca, 0xbd08a39f, 0xb8fbaf47,
    0xb504f333, 0xb123f581, 0xad583eea, 0xa9a15ab4,
    0xa5fed6a9, 0xa2704303, 0x9ef53260, 0x9b8d39b9,
    0x9837f051, 0x94f4efa8, 0x91c3d373, 0x8ea4398b,
    0x8b95c1e3, 0x88980e80, 0x85aac367, 0x82cd8698,
};

var balance_timer: ke.Timer = undefined;
var balance_dpc: ke.Dpc = .init(balance);

// LCG values taken from FreeBSD.
var lcg = std.Random.lcg.Wrapping(u32).init(0, 69069, 5);

pub const RunQueue = struct {
    /// Bitmap of non-empty queues. A set bit represents a non-empty queue.
    status: u64,
    queues: [runqueues_n]rtl.List,
};

pub const PreemptionReason = enum(u8) {
    None,
    /// A higher priority thread was readied.
    HigherPriority,
};

/// Per-CPU scheduler data.
pub const PerCpu = struct {
    /// Current load on this CPU (number of ready threads)
    load: std.atomic.Value(usize),
    /// Average load on this CPU
    load_avg: std.atomic.Value(usize),
    /// Estimated load on this CPU
    est_load_avg: std.atomic.Value(usize),
    /// Number of threads on this CPU that can migrate.
    migratable: std.atomic.Value(usize),
    /// Lock over this CPU's queues.
    queues_lock: ke.SpinLock,
    /// Array of queues from which to pick realtime threads from.
    realtime_queue: RunQueue,
    /// Calendar queue.
    calendar_queue: RunQueue,
    /// Queue of idle threads.
    idle_queue: rtl.List,
    /// The index from which to pick the next thread.
    runidx: u8,
    /// The index on which the next thread is going to be inserted.
    insidx: u8,
    /// Set on idle thread entry to try stealing work.
    steal_work: bool,
    /// Atomic byte for getting the current thread's priority locklessly.
    current_thread_prio: std.atomic.Value(u8),
    /// DPC for rescheduling.
    resched_dpc: ke.Dpc,
    /// Timer for quantum expiration.
    resched_timer: ke.Timer,
    /// Flag indicating the start of the scheduling timer.
    start_timer: bool,
    /// The reason why the current thread was preempted.
    preemption_reason: PreemptionReason,
    /// Currently running thread.
    current_thread: ?*ke.Thread,
    /// Per-CPU idle thread.
    idle_thread: ?*ke.Thread,
    /// Thread selected for preemption.
    next_thread: ?*ke.Thread,
    /// Rotating offset to break ties in pick_cpu()
    pick_offset: usize,
};

pub const Average = struct {
    load: usize,
    // Estimated load
    est: usize,
    // Amount of the period that has been accounted for
    period_contrib: usize,
    /// Timestamp (us) up to which history has been accounted.
    last_update: u64,
};

pub const percpu = ke.CpuLocal(PerCpu, undefined);

/// Apply `n` microseconds worth of decay to `val`.
fn pelt_do_decay(val: u64, n: u64) u64 {
    const shift = n / pelt_halflife;

    if (shift >= 64) {
        // Way too big, return 0
        return 0;
    }

    var v = val >> @intCast(shift);
    const rem = n % pelt_halflife;

    if (rem != 0) {
        // Fractional remainder, index into the table.
        // The table gives us 2^32 * 2^(-k/pelt_decay), shift by 32 to remove the 2^32.
        v = (v * pelt_inv_table[(rem * pelt_decay) / pelt_halflife]) >> 32;
    }

    return v;
}

fn pelt_update(avg: *Average, runnable: bool) void {
    const now = ke.time.read_time() / std.time.ns_per_us;
    const new_delta = now - avg.last_update;

    if (new_delta == 0) return;

    avg.last_update = now;

    // Add the partial period we had before.
    var delta = new_delta + avg.period_contrib;
    const periods = delta / pelt_scale;

    var contrib = new_delta;

    if (periods > 0) {
        // Decay old history. Only whole periods decay, the current
        // partial period keeps accruing at full weight until it completes.
        const decay_time = periods * pelt_scale;
        avg.load = pelt_do_decay(avg.load, decay_time);

        // Now contribute new history, including partial periods.
        //   d1              d2               d3
        // |-----------|----------------|----------------|
        // previous    full periods      current period
        // remainder                     remainder
        //
        // The total contribution would be
        //                 p-1
        // d1 * y^p + p *  Sum y^n + d3
        //                 n=1
        const d1 = pelt_scale - avg.period_contrib;

        // d1 * y^p
        const c1 = pelt_do_decay(d1, decay_time);

        // For a full period, its contribution is 1024y + 1024y^2 + ... + 1024y^(p-1)
        //                            inf
        // We know load_avg_max = p * Sum y^n
        //                            n=0
        // So, load_avg_max - load_avg_max * y^p yields:
        //     p-1                                                    p-1
        // p * Sum y^n, subtracting the first term (n=0) gives us p * Sum
        //     n=0                                                    n=1
        const d2 = pelt_load_avg_max - pelt_do_decay(pelt_load_avg_max, decay_time) - pelt_scale;

        // Get the partial period remainder.
        delta %= pelt_scale;

        contrib = c1 + d2 + delta;
    }

    if (runnable) avg.load += contrib;

    // Remember our period remainder.
    avg.period_contrib = delta;
}

// Idle-class threads never take part in load tracking.
fn tracks_load_avg(td: *ke.Thread) bool {
    return td.base_priority_class() != .Idle;
}

fn pelt_update_td(td: *ke.Thread, cpu: ?*PerCpu, runnable: bool) void {
    if (!tracks_load_avg(td)) return;

    const old = td.avg.load;
    pelt_update(&td.avg, runnable);
    if (cpu) |c| {
        const delta = @as(i64, @intCast(td.avg.load)) - @as(i64, @intCast(old));
        _ = c.load_avg.fetchAdd(@bitCast(delta), .monotonic);
    }
}

// Called when a thread enters the runnable state (running or ready).
fn attach_load_avg(cpu: *PerCpu, td: *ke.Thread) void {
    if (!tracks_load_avg(td)) return;

    if (td.avg.last_update == 0) {
        td.avg.last_update = ke.time.read_time() / std.time.ns_per_us;
    } else {
        pelt_update_td(td, null, false);
    }

    _ = cpu.load_avg.fetchAdd(td.avg.load, .monotonic);
    _ = cpu.est_load_avg.fetchAdd(td.avg.est, .monotonic);
}

// Called when a thread exits the runnable state.
pub fn detach_load_avg(cpu: *PerCpu, td: *ke.Thread) void {
    if (!tracks_load_avg(td)) return;

    pelt_update_td(td, cpu, true);
    _ = cpu.load_avg.fetchSub(td.avg.load, .monotonic);
    _ = cpu.est_load_avg.fetchSub(td.avg.est, .monotonic);
}

/// Handle preemption.
/// This is called in DPC dispatch when it notices `next_thread` is set.
pub fn handle_preemption(cpu: *PerCpu) void {
    cpu.queues_lock.acquire_no_ipl();

    const cur = cpu.current_thread.?;

    const next = cpu.next_thread orelse {
        cpu.queues_lock.release_no_ipl();
        return;
    };

    cpu.next_thread = null;
    cpu.current_thread_prio.store(next.priority, .monotonic);

    cpu.queues_lock.release_no_ipl();
    cur.lock.acquire_no_ipl();

    if (cur != cpu.idle_thread and cur.state.load(.monotonic) != .Blocked) {
        // Put it back in the queue.
        cpu.queues_lock.acquire_no_ipl();
        insert_in_queue(cpu, cur, cpu.preemption_reason == .HigherPriority);
        cur.cpu = ke.cpu.current();
        cpu.queues_lock.release_no_ipl();
    }

    next.lock.acquire_no_ipl();
    next.lock.release_no_ipl();

    do_switch(cpu, cur, next);

    // cur.lock dropped
}

/// Called every time slice in DPC context.
pub fn clock(_: *ke.Dpc, _: ?*anyopaque) void {
    const cpu = percpu.local();
    std.debug.assert(ki.ipl.current() == .Dispatch);

    const curtd = cpu.current_thread orelse return;

    curtd.lock.acquire_no_ipl();
    defer curtd.lock.release_no_ipl();

    cpu.queues_lock.acquire_no_ipl();
    defer cpu.queues_lock.release_no_ipl();

    // Advance the insert index every tick, while keeping a separation of 1 with runidx.
    // This ensures fairness.
    if (cpu.runidx == cpu.insidx) {
        cpu.insidx = (cpu.insidx + 1) % runqueues_n;

        if (cpu.calendar_queue.queues[cpu.runidx].is_empty()) {
            // Ensure we don't point at an empty queue.
            cpu.runidx = cpu.insidx;
        }
    }

    if (curtd.base_priority_class() == .Batch) {
        curtd.run_time += config.sched_timeslice;

        clamp_time(curtd);
        recompute_priority(curtd);
    }

    pelt_update_td(curtd, cpu, true);

    if (cpu.next_thread != null) {
        // Another thread was already selected for preemption.
        return;
    }

    // Pick a new thread to run.
    const newtd = select_thread(curtd, cpu, false);

    // Ensure the timer gets reloaded.
    cpu.start_timer = true;
    cpu.next_thread = newtd;

    if (newtd) |n| {
        cpu.current_thread_prio.store(n.priority, .monotonic);
    }
}

/// Enqueue a thread.
pub fn enqueue(td: *ke.Thread) void {
    const ipl = td.lock.acquire();
    const cpu = pick_cpu(td);
    enqueue_on_cpu(cpu, td);
    td.lock.release(ipl);
}

/// Yield on the current CPU.
pub fn yield() void {
    const ipl = ke.ipl.raise(.Dispatch);
    const td = percpu.local().current_thread.?;

    td.lock.acquire_no_ipl();

    const cpu = percpu.local();
    if (td != cpu.idle_thread and td.state.load(.monotonic) == .Running) {
        cpu.queues_lock.acquire_no_ipl();
        insert_in_queue(cpu, td, false);
        td.cpu = ke.cpu.current();
        cpu.queues_lock.release_no_ipl();
    }

    yield_locked();

    // td lock released
    ke.ipl.lower(ipl);
}

/// Block the currently running thread.
pub fn block() void {
    const ipl = ke.ipl.raise(.Dispatch);
    const td = percpu.local().current_thread.?;

    td.lock.acquire_no_ipl();
    block_locked(td);

    // td lock released
    ke.ipl.lower(ipl);
}

/// Block the currently running thread with its lock held.
pub fn block_locked(curtd: *ke.Thread) void {
    curtd.state.store(.Blocked, .monotonic);
    curtd.sleep_start = ke.time.read_time();
    curtd.runq = null;

    detach_load_avg(percpu.local(), curtd);

    // WMA with 75% old and 25% new load.
    // This is used to estimate the thread's load
    // when it'll wake back up.
    const sample = curtd.avg.load;
    if (sample >= curtd.avg.est) {
        curtd.avg.est = sample;
    } else {
        curtd.avg.est = (3 * curtd.avg.est + sample) / 4;
    }

    yield_locked();
}

/// Yield the current CPU with the current thread already locked at Dispatch IPL.
pub fn yield_locked() void {
    const sched_cpu = percpu.local();

    sched_cpu.queues_lock.acquire_no_ipl();

    const cur = sched_cpu.current_thread;
    var next = sched_cpu.next_thread;

    if (next != null) {
        sched_cpu.next_thread = null;
    } else {
        // Pick a new thread to run.
        next = select_thread(null, sched_cpu, false);
    }

    if (next == null) {
        // Nothing to run, go idle.
        next = sched_cpu.idle_thread;
        sched_cpu.steal_work = true;
    }

    if (next) |n| {
        sched_cpu.current_thread_prio.store(n.priority, .monotonic);
    }

    sched_cpu.queues_lock.release_no_ipl();

    if (next != null and cur.? != next.?) {
        // Switch into the thread. Take its lock here to ensure it is not still on its stack.
        next.?.lock.acquire_no_ipl();
        next.?.lock.release_no_ipl();

        do_switch(sched_cpu, cur.?, next.?);
    } else {
        // Ensure curthread is not marked as selected.
        cur.?.state.store(.Running, .monotonic);
        cur.?.lock.release_no_ipl();
    }

    // cur lock dropped
}

pub fn unblock_locked(td: *ke.Thread) void {
    std.debug.assert(td.lock.is_locked());
    std.debug.assert(td.state.load(.monotonic) == .Blocked);

    const delta = (ke.time.read_time() - td.sleep_start) / std.time.ns_per_ms;

    td.sleep_time += delta;

    if (delta >= config.sched_timeslice and td.base_priority_class() == .Batch) {
        // If we have slept for more than a tick, update interactivity.
        clamp_time(td);
        recompute_priority(td);
    }

    // Enqueue the thread
    const cpu = pick_cpu(td);
    enqueue_on_cpu(cpu, td);
}

/// Unblock a thread.
pub fn unblock(td: *ke.Thread) void {
    const ipl = td.lock.acquire();

    unblock_locked(td);

    td.lock.release(ipl);
}

pub fn update_priority_locked(td: *ke.Thread, new_prio: u8) void {
    std.debug.assert(td.lock.is_locked());

    const old_prio = td.priority;

    const c = td.cpu orelse {
        td.priority = new_prio;
        return;
    };

    const cpu = percpu.remote(c);

    cpu.queues_lock.acquire_no_ipl();
    defer cpu.queues_lock.release_no_ipl();

    td.priority = new_prio;

    const state = td.state.load(.monotonic);

    if (state == .Ready) {
        // Remove it from its queue and add it back.
        remove_from_queue(cpu, td);
        insert_in_queue(cpu, td, false);
        td.cpu = c;
    }

    if (state == .Running) {
        std.debug.assert(td.last_cpu == c);

        cpu.current_thread_prio.store(new_prio, .monotonic);

        // Do nothing else on promotion.
        if (new_prio >= old_prio) return;

        // Demotion: try to preempt the thread if possible.
        if (cpu.next_thread != null) return;

        // Only try picking from the realtime queue as batch threads don't preempt each other.
        const next = pick_realtime_thread(cpu, new_prio + 1, false) orelse return;
        _ = cpu.load.fetchSub(1, .monotonic);

        if (!next.pinned) {
            _ = cpu.migratable.fetchSub(1, .monotonic);
        }

        cpu.next_thread = next;
        cpu.preemption_reason = .HigherPriority;
        cpu.current_thread_prio.store(next.priority, .monotonic);

        ki.ipl.set_softint_pending(c, .Dispatch);

        if (c != ke.cpu.current()) {
            ki.impl.send_resched_ipi(c);
        }
    }

    if (state == .Selected or cpu.next_thread == td) {
        // Thread is committed to run on but not running, update the hint.
        cpu.current_thread_prio.store(new_prio, .monotonic);
        return;
    }

    // XXX: Handle Selected threads so that they are placed properly?
}

/// Initialize a CPU for use by the scheduler.
fn init_cpu() linksection(r.init) void {
    var cpu = percpu.local();

    cpu.* = .{
        .insidx = 0,
        .runidx = 0,
        .calendar_queue = .{ .status = 0, .queues = undefined },
        .realtime_queue = .{ .status = 0, .queues = undefined },
        .queues_lock = .init(),
        .idle_queue = undefined,
        .steal_work = false,
        .load = .init(0),
        .load_avg = .init(0),
        .est_load_avg = .init(0),
        .migratable = .init(0),
        .current_thread_prio = .init(0),
        .resched_dpc = .init(ki.sched.clock),
        .resched_timer = undefined,
        .start_timer = false,
        .preemption_reason = .None,
        .current_thread = null,
        .idle_thread = null,
        .next_thread = null,
        .pick_offset = 0,
    };

    cpu.resched_timer.init();
    cpu.idle_queue.init();

    for (0..runqueues_n) |i| {
        cpu.calendar_queue.queues[i].init();
    }

    for (0..runqueues_n) |i| {
        cpu.realtime_queue.queues[i].init();
    }
}

comptime {
    _ = r.percpu_init_set.insert(&init_cpu);
}

/// Called on CPU 0 to initialize load balancing mechanisms.
pub fn late_init() linksection(r.init) void {
    balance_timer.init();
    ke.timer.set(&balance_timer, balance_interval * std.time.ns_per_ms, &balance_dpc);
}

fn calendar_queue_increment(cpu: *PerCpu) void {
    cpu.runidx = (cpu.runidx + 1) % runqueues_n;

    // Ensure insidx is always one ahead of runidx
    if (cpu.runidx == cpu.insidx) {
        cpu.insidx = (cpu.insidx + 1) % runqueues_n;
    }
}

fn pick_realtime_thread(cpu: *PerCpu, minprio: u8, migrate: bool) ?*ke.Thread {
    std.debug.assert(cpu.queues_lock.is_locked());

    const runq = &cpu.realtime_queue;

    if (runq.status == 0) return null;

    // Search higher priority queues first.
    var i: usize = ke.Thread.Priority.max;

    qloop: while (i >= minprio and i > 0) : (i -= 1) {
        const bit = (@as(u64, 1) << @intCast(i));

        if (runq.status & bit == 0) {
            // Queue is empty.
            continue;
        }

        const curr_queue = &runq.queues[i];

        std.debug.assert(!curr_queue.is_empty());

        // Get the first thread of the queue.
        var td: *ke.Thread = @fieldParentPtr("runq_link", curr_queue.first());

        td.state.store(.Selected, .monotonic);

        if (migrate) {
            // Find the first thread that is not pinned.
            while (td.pinned) {
                const entry = td.runq_link.next;

                // Every thread is pinned, go through another queue
                if (entry == &curr_queue.head) continue :qloop;

                td = @fieldParentPtr("runq_link", entry);
            }
        }

        // Remove it from the queue.
        td.runq_link.remove();

        if (curr_queue.is_empty()) {
            // Queue is now empty, clear its bit.
            runq.status &= ~bit;
        }

        return td;
    }

    return null;
}

fn pick_batch_thread(cpu: *PerCpu, migrate: bool) ?*ke.Thread {
    std.debug.assert(cpu.queues_lock.is_locked());
    const runq = &cpu.calendar_queue;

    if (runq.status == 0) return null;

    // Search all queues, starting from runidx.
    var i: usize = cpu.runidx;
    var cnt: usize = 0;

    qloop: while (cnt < runqueues_n) : ({
        i = (i + 1) % runqueues_n;
        cnt += 1;
    }) {
        const bit = (@as(u64, 1) << @intCast(i));

        if (runq.status & bit == 0) {
            // Queue is empty.
            continue;
        }

        const curr_queue = &runq.queues[i];

        std.debug.assert(!curr_queue.is_empty());

        // Get the first thread of the queue.
        var td: *ke.Thread = @fieldParentPtr("runq_link", curr_queue.first());

        td.state.store(.Selected, .monotonic);

        if (migrate) {
            // Find the first thread that is not pinned.
            while (td.pinned) {
                const entry = td.runq_link.next;

                // Every thread is pinned, go through another queue
                if (entry == &curr_queue.head) continue :qloop;

                td = @fieldParentPtr("runq_link", entry);
            }
        }

        // Remove it from the queue.
        td.runq_link.remove();

        if (curr_queue.is_empty()) {
            // Queue is now empty, clear its bit and increment runidx.
            runq.status &= ~bit;

            if (!migrate) {
                calendar_queue_increment(cpu);
            }
        }

        return td;
    }

    return null;
}

fn pick_idle_thread(cpu: *PerCpu, migrate: bool) ?*ke.Thread {
    std.debug.assert(cpu.queues_lock.is_locked());
    if (cpu.idle_queue.is_empty()) return null;

    // Just get the first thread from the queue.
    const td: *ke.Thread = @fieldParentPtr("runq_link", cpu.idle_queue.first());

    if (migrate and td.pinned) {
        return null;
    }

    td.state.store(.Selected, .monotonic);

    // We can safely remove it.
    td.runq_link.remove();

    return td;
}

fn insert_in_list(list: *rtl.List, link: *rtl.List.Entry, head: bool) void {
    if (head) list.insert_head(link) else list.insert_tail(link);
}

// Insert a thread into its respective queue.
fn insert_in_queue(cpu: *PerCpu, td: *ke.Thread, preempted: bool) void {
    std.debug.assert(cpu.queues_lock.is_locked());

    td.cpu = null;

    if (td.priority_class() == .Realtime or td.is_interactive()) {
        // Insert in realtime queue.
        cpu.realtime_queue.status |=
            (@as(u64, 1) << @intCast(td.priority));

        insert_in_list(&cpu.realtime_queue.queues[td.priority], &td.runq_link, preempted);
        td.runq = &cpu.realtime_queue;
        td.runq_idx = @intCast(td.priority);
    } else if (td.priority_class() == .Batch) {
        // Insert in calendar queue.
        // The insertion index is determined by insidx and the the priority of the thread,
        // higher priority threads will be put closer to insidx, which ensures that they are ran more frequently.
        var idx = (cpu.insidx + (ke.Thread.Priority.high_batch - td.priority)) % runqueues_n;

        if (preempted) {
            // Thread was preempted involuntarily, ensure it runs next.
            idx = cpu.runidx;
        }

        cpu.calendar_queue.status |= (@as(u64, 1) << @intCast(idx));

        insert_in_list(&cpu.calendar_queue.queues[idx], &td.runq_link, false);
        td.runq = &cpu.calendar_queue;
        td.runq_idx = @intCast(idx);
    } else {
        // Insert in idle queue.
        insert_in_list(&cpu.idle_queue, &td.runq_link, preempted);
        td.runq = null;
        td.runq_idx = 0;
    }

    td.state.store(.Ready, .monotonic);
    _ = cpu.load.fetchAdd(1, .monotonic);

    if (!td.pinned) {
        _ = cpu.migratable.fetchAdd(1, .monotonic);
    }
}

// Remove a thread from a queue.
fn remove_from_queue(cpu: *PerCpu, td: *ke.Thread) void {
    std.debug.assert(td.lock.is_locked());
    std.debug.assert(cpu.queues_lock.is_locked());

    // Decrease load.
    _ = cpu.load.fetchSub(1, .monotonic);

    if (!td.pinned) {
        _ = cpu.migratable.fetchSub(1, .monotonic);
    }

    // Remove the thread from its queue.
    td.runq_link.remove();

    if (td.runq) |rq| {
        if (rq.queues[td.runq_idx].is_empty()) {
            // Clear the bit.
            rq.status &= ~(@as(u64, 1) << @intCast(td.runq_idx));

            if (td.priority_class() == .Batch) {
                calendar_queue_increment(cpu);
            }
        }
    }
}

// Update recent history for a thread.
fn clamp_time(td: *ke.Thread) void {
    const max = 5 * std.time.ms_per_s;
    const sum = td.run_time + td.sleep_time;

    if (sum < max) return;

    if (sum > max * 2) {
        // History is way out of range (>10s), reset it.
        // Preserve the dominant side to avoid flipping interactivity classification.
        if (td.run_time > td.sleep_time) {
            td.run_time = max;
            td.sleep_time = 1;
        } else {
            td.sleep_time = max;
            td.run_time = 1;
        }

        return;
    }

    if (sum > ((max / 5) * 6)) {
        // History is moderately out of range (>6s), halve both values.
        // Keeps the sleep/run ratio intact while pulling the sum back in range.
        td.run_time /= 2;
        td.sleep_time /= 2;
        return;
    }

    // History is slightly out of range (5s-6s), 20% decay.
    // Gradually ages out old history without disturbing the ratio.
    td.run_time = (td.run_time / 5) * 4;
    td.sleep_time = (td.sleep_time / 5) * 4;
}

// Compute the interactivity score for a thread.
fn interactive_score(td: *ke.Thread) usize {
    var div: usize = undefined;
    var score: usize = undefined;

    // Calculate the interactivity penalty.
    if (td.sleep_time > td.run_time) {
        div = @max(1, td.sleep_time / scaling_factor);
        score = td.run_time / div;
    } else if (td.run_time > td.sleep_time) {
        div = @max(1, td.run_time / scaling_factor);
        score = (scaling_factor + scaling_factor - (td.sleep_time / div));
    } else if (td.run_time != 0) {
        score = scaling_factor;
    } else return 0;

    // Add niceness values to the penalty, this makes it easier for threads with
    // lower nice values (higher priority) to be considered interactive.
    var signed_score: isize = @intCast(score);
    signed_score += td.nice;
    score = @intCast(@max(0, signed_score));

    return score;
}

// Recompute the base priority for a thread from interactivity and nice.
fn recompute_priority(td: *ke.Thread) void {

    // Priority is computed only for time-shared (batch) thread based on
    // interactivity and nice. If the thread is determined interactive, it is
    // effectively promoted to real-time with a lower priority than actual
    // real-time threads. If the thread is determined non-interactive,
    // priority is calculated based on recent CPU usage and nice.
    const score = interactive_score(td);

    const base: u8 = if (score < interactivity_threshold)
        // Choose a priority based on score, the lower the score,
        // the higher the priority it will be.
        // This is a simple formula I came up with that is probably good enough.
        @intCast(ke.Thread.Priority.low_interactive + ((interactivity_threshold - score) / 2))
    else blk: {
        // Thread is not interactive, compute priority from recent CPU usage.
        // cpu_pri_off is the fraction of the history window spent running,
        // scaled to [0, batch_range). A thread that spent all its time running
        // gets cpu_pri_off = batch_range - 1 (lowest priority).
        // A thread that barely ran gets cpu_pri_off = 0 (highest batch priority).
        // This is a pretty straightforward formula, which /should/ be good enough.
        const cpu_range = ke.Thread.Priority.batch_range;
        const window = if (td.run_time + td.sleep_time == 0) @as(u64, 1) else td.run_time + td.sleep_time;
        const cpu_pri_off: u8 = @intCast((td.run_time * (cpu_range - 1)) / window);

        // nice offset: negative nice increases priority value, positive decreases it.
        // Clamped to half the range to avoid pushing priority out of bounds before clamping.
        const nice_off = std.math.clamp(
            -@as(i32, td.nice),
            -@as(i32, cpu_range / 2),
            @as(i32, cpu_range / 2),
        );

        const raw = @as(i32, ke.Thread.Priority.low_batch) +
            @as(i32, cpu_pri_off) +
            nice_off;

        break :blk @intCast(std.math.clamp(
            raw,
            ke.Thread.Priority.low_batch,
            ke.Thread.Priority.high_batch,
        ));
    };

    td.base_priority = base;
    td.priority = td.effective_priority();
}

// Return whether or not a thread with given priority and interactivity should get preempted by `td`.
fn should_prio_preempt(td: *ke.Thread, other_prio: u8, remote: bool) bool {
    const class = ke.Thread.Priority.class_from_prio(other_prio);

    if (td.priority <= other_prio) {
        // If our priority is lower or equal, ignore.
        return false;
    }

    if (class == .Idle) {
        // Non-idle threads always preempt idle-priority threads.
        return true;
    }

    if (class == .Batch and td.is_interactive() and other_prio < ke.Thread.Priority.low_interactive and remote) {
        // Interactive threads always preempt batch non-interactive ones on remote CPUs.
        return true;
    }

    // Preempt if the priority exceeds the preemption threshold (i.e the thread is real-time)
    // or if the thread is interactive.
    // Interactive threads may still preempt each other based on interactivity.
    if ((td.priority >= preempt_threshold or td.is_interactive())) {
        return true;
    }

    return false;
}

// Return whether or not `td` should preempt `cur`.
// This is called with cur's CPU queue lock held.
fn should_preempt(td: *ke.Thread, cur: *ke.Thread, remote: bool) bool {
    // Always preempt the idle thread.
    return should_prio_preempt(td, cur.priority, remote);
}

// Return whether or not `td` should preempt the thread running on `cpu`.
// This is done in a lock-free manner.
fn should_preempt_cpu(td: *ke.Thread, cpu: *PerCpu, remote: bool) bool {
    const prio = cpu.current_thread_prio.load(.monotonic);
    return should_prio_preempt(td, prio, remote);
}

// Enqueue a thread on a CPU.
fn enqueue_on_cpu(c: u32, td: *ke.Thread) void {
    std.debug.assert(td.lock.is_locked());

    const cpu = percpu.remote(c);
    cpu.queues_lock.acquire_no_ipl();

    defer cpu.queues_lock.release_no_ipl();

    attach_load_avg(cpu, td);

    if (cpu.current_thread != null and should_preempt_cpu(td, cpu, c != ke.cpu.current())) {
        // We can preempt the current thread, first check whether or not there
        // is already a next thread selected, and if we can preempt it.

        const next = cpu.next_thread;
        var can_preempt = true;

        if (next) |n| {
            if (should_preempt(td, n, c != ke.cpu.current())) {
                // This thread can preempt the next thread,
                // put the next thread back into a queue as the first element.
                insert_in_queue(cpu, n, true);
                n.cpu = c;
            } else {
                // The next thread is higher priority, we can't preempt it.
                can_preempt = false;
            }
        }

        if (can_preempt) {
            // Preempt the CPU.
            cpu.next_thread = td;
            cpu.preemption_reason = .HigherPriority;
            td.cpu = c;
            td.state.store(.Selected, .monotonic);
            ki.ipl.set_softint_pending(c, .Dispatch);

            cpu.current_thread_prio.store(td.priority, .monotonic);

            if (c != ke.cpu.current()) {
                // Send an IPI.
                ki.impl.send_resched_ipi(c);
            }

            // queues_lock dropped
            return;
        }
    }

    // Normal enqueue path.
    // Add the thread to its appropriate queue.
    insert_in_queue(cpu, td, false);

    td.cpu = c;

    if (cpu.resched_timer.state.load(.monotonic) == .Stopped) {
        cpu.start_timer = true;
        ki.ipl.set_softint_pending(c, .Dispatch);
    }

    // queues_lock dropped
}

// Find a suitable CPU to run the thread.
fn pick_cpu(td: *ke.Thread) u32 {
    // CPU selection policy in order:
    // 1. Pick the last CPU the thread ran on if it would run immediately or if it's pinned.
    // 2. Pick the least loaded CPU on which the thread can run immediately.
    // 3. Pick the least loaded CPU overall.

    const curcpu = ke.cpu.current();

    if (td.last_cpu) |cpu| {
        var ran_recently = true;

        if (td.sleep_start != 0) {
            const delta = ke.time.read_time() - td.sleep_start;

            // If we haven't been on this CPU in the last second, don't bother.
            if (delta > std.time.ns_per_s) {
                ran_recently = false;
            }

            td.sleep_start = 0;
        }

        const sched_cpu = percpu.remote(cpu);

        // If we can preempt and have ran recently on this CPU, run on it.
        if ((should_preempt_cpu(td, sched_cpu, cpu != curcpu) and ran_recently) or td.pinned)
            return cpu;
    }

    // Check all CPUs, keeping track of the least loaded one overall and the
    // least loaded preemptible one.
    // We try to pick the CPU on which we can run immediately, but if there is
    // a tie we use the average load to break it.

    const local = percpu.local();
    local.pick_offset +%= 1;

    var least: ?u32 = null;
    var least_load: usize = 0;
    var least_preempt: ?u32 = null;
    var least_preempt_load: usize = 0;
    var least_preempt_depth: usize = 0;
    var least_depth: usize = 0;

    for (0..ke.ncpus) |n| {
        const i = (local.pick_offset + n) % ke.ncpus;
        const cpu: u32 = @truncate(i);
        const data = percpu.remote(cpu);
        const depth = data.load.load(.monotonic);
        const avg = @max(data.est_load_avg.load(.monotonic), data.load_avg.load(.monotonic));

        if (least == null or depth < least_depth or
            (depth == least_depth and avg < least_load))
        {
            least = cpu;
            least_depth = depth;
            least_load = avg;
        }

        if (should_preempt_cpu(td, data, i != curcpu)) {
            if (least_preempt == null or depth < least_preempt_depth or (depth == least_preempt_depth and avg < least_preempt_load)) {
                least_preempt = cpu;
                least_preempt_depth = depth;
                least_preempt_load = avg;
            }
        }
    }

    // If we found a preemptible CPU, pick that one. Otherwise pick the least loaded one.
    return least_preempt orelse least.?;
}

// Find a thread to preempt `cur` with.
fn select_thread(cur: ?*ke.Thread, cpu: *PerCpu, migrate: bool) ?*ke.Thread {
    // First try to pick from the realtime queues.
    if (pick_realtime_thread(cpu, if (cur) |c| c.priority else 0, migrate)) |td| {
        _ = cpu.load.fetchSub(1, .monotonic);
        if (!td.pinned) {
            _ = cpu.migratable.fetchSub(1, .monotonic);
        }
        return td;
    }

    // Nothing lower can preempt this thread.
    if (cur != null and (cur.?.priority_class() == .Realtime or cur.?.is_interactive())) {
        return null;
    }

    // Then try picking a batch thread.
    if (pick_batch_thread(cpu, migrate)) |td| {
        _ = cpu.load.fetchSub(1, .monotonic);
        if (!td.pinned) {
            _ = cpu.migratable.fetchSub(1, .monotonic);
        }
        return td;
    }

    if (cur != null and cur.?.priority_class() == .Idle) {
        // Idle threads don't preempt each other
        return null;
    }

    // Finally try picking from the idle queue.
    if (pick_idle_thread(cpu, migrate)) |td| {
        _ = cpu.load.fetchSub(1, .monotonic);
        if (!td.pinned) {
            _ = cpu.migratable.fetchSub(1, .monotonic);
        }
        return td;
    }

    // Nothing to run.
    return null;
}

// Execute a context switch on `cpu`.
fn do_switch(cpu: *PerCpu, cur: *ke.Thread, next: *ke.Thread) void {
    cpu.current_thread = next;
    next.last_cpu = ke.cpu.current();

    next.state.store(.Running, .monotonic);

    // Do machine-dependent switch.
    cur.context.switch_to(&next.context);
}

fn find_most_loaded(exclude: ?*ke.CpuMask, steal: bool) ?u32 {
    var most: ?u32 = null;
    var most_load: usize = 0;
    var most_load_avg: usize = 0;

    for (0..ke.ncpus) |i| {
        if (exclude) |mask| {
            if (mask.get(i)) {
                continue;
            }
        }

        const cpu = percpu.remote(@truncate(i));

        // Check migratable threads.
        if (cpu.migratable.load(.monotonic) == 0) {
            continue;
        }

        // When work-stealing, use the load average
        // to break ties only, otherwise rely on thread count.
        // Load balancing relies solely on the load average to try
        // to relieve longer-term CPU pressure.
        const load_avg = @max(cpu.est_load_avg.load(.monotonic), cpu.load_avg.load(.monotonic));
        const load = if (steal) cpu.migratable.load(.monotonic) else load_avg;

        if (most == null) {
            most = @truncate(i);
            most_load = load;
            most_load_avg = load_avg;
        } else if (load > most_load) {
            most = @truncate(i);
            most_load = load;
            most_load_avg = load_avg;
        } else if (load == most_load and steal) {
            if (load_avg > most_load_avg) {
                most = @truncate(i);
                most_load = load;
                most_load_avg = load_avg;
            }
        }
    }

    return most;
}

fn find_least_loaded(exclude: ?*ke.CpuMask) ?u32 {
    var least: ?u32 = null;
    var least_load: usize = 0;

    for (0..ke.ncpus) |i| {
        if (exclude) |mask| {
            if (mask.get(i)) {
                continue;
            }
        }

        const cpu = percpu.remote(@truncate(i));
        const load = @max(cpu.est_load_avg.load(.monotonic), cpu.load_avg.load(.monotonic));

        if (least == null) {
            least = @truncate(i);
            least_load = load;
        } else if (load < least_load) {
            least = @truncate(i);
            least_load = load;
        }
    }

    return least;
}

fn steal_thread_from_cpu(cpu: *PerCpu, curcpu: ?*PerCpu) ?*ke.Thread {
    cpu.queues_lock.acquire_no_ipl();
    defer cpu.queues_lock.release_no_ipl();

    if (curcpu != null and curcpu.?.load.load(.monotonic) > 0)
        return null;

    const td = select_thread(null, cpu, true);

    if (td) |t| {
        detach_load_avg(cpu, t);
    }

    return td;
}

fn steal_work(cpu: u32) ?*ke.Thread {
    const most = find_most_loaded(null, true);
    const c = percpu.remote(cpu);

    if (most == cpu) {
        // We're the most loaded CPU, nothing to steal.
        return null;
    }

    if (most) |other| {
        const sched_other = percpu.remote(other);
        if (sched_other.migratable.load(.monotonic) < steal_threshold) {
            return null;
        }

        const ipl = ke.ipl.raise(.Dispatch);
        const td = steal_thread_from_cpu(sched_other, c);
        ke.ipl.lower(ipl);
        return td;
    }

    return null;
}

/// Idle loop for a CPU. Must be set up in the idle thread.
pub fn idle(_: ?*anyopaque) noreturn {
    const cpu = percpu.local();
    const cpu_id = ke.cpu.current();

    while (true) {
        // Racy but only a hint anyway
        const next = @atomicLoad(?*ke.Thread, &cpu.next_thread, .monotonic);

        if (cpu.load.load(.monotonic) != 0 or next != null) {
            ke.sched.yield();
            continue;
        }

        if (cpu.steal_work) {
            // Try to steal work once when we enter the idle loop,
            // if there is nothing to steal, go into a power-saving loop
            // until someone else wakes us up.
            cpu.steal_work = false;

            // Steal a thread.
            if (steal_work(cpu_id)) |td| {
                // Enqueue it on this CPU.
                const ipl = td.lock.acquire();

                enqueue_on_cpu(cpu_id, td);
                td.lock.release(ipl);
            }
        }

        std.atomic.spinLoopHint();
    }
}

/// Called every second to balance work between CPUs on CPU0.
/// Takes a thread from the most loaded CPU and puts it on the least loaded one.
fn balance(_: *ke.Dpc, _: ?*anyopaque) void {
    var high_mask = ke.CpuMask.init(false);
    var low_mask: ke.CpuMask = undefined;

    while (true) {
        const high = find_most_loaded(&high_mask, false);

        if (high == null or percpu.remote(high.?).migratable.load(.monotonic) == 0) {
            // No highest loaded CPU.
            break;
        }

        // Don't steal from this CPU again.
        high_mask.set(high.?);
        low_mask = high_mask;

        if (high_mask.is_all(true)) {
            // All CPUs are masked, nothing to steal.
            break;
        }

        const low = find_least_loaded(&low_mask);

        if (low == null) {
            // No lowest loaded CPU.
            break;
        }

        const high_cpu = percpu.remote(high.?);
        const low_cpu = percpu.remote(low.?);

        const high_avg = @max(high_cpu.load_avg.load(.monotonic), high_cpu.est_load_avg.load(.monotonic));
        const low_avg = @max(low_cpu.load_avg.load(.monotonic), low_cpu.est_load_avg.load(.monotonic));

        if (high_avg -| low_avg < pelt_load_avg_max / 2) {
            // Only balance when the imbalance is high.
            break;
        }

        // Steal a thread from the high CPU and put it on the low CPU.
        const sched_high = percpu.remote(high.?);
        const td = steal_thread_from_cpu(sched_high, null);

        if (td) |thread| {
            thread.lock.acquire_no_ipl();

            enqueue_on_cpu(low.?, thread);
            thread.lock.release_no_ipl();
        }

        // Don't shuffle threads around.
        high_mask.set(low.?);
    }

    const offset = lcg.next() % balance_interval;
    const ms = (balance_interval) + offset;

    ke.timer.set(&balance_timer, ms * std.time.ns_per_ms, &balance_dpc);
}
