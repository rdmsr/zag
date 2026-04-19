//! Kernel scheduler inspired by FreeBSD's ULE scheduler.
//!
//! ## Overview
//!
//! Threads are divided into three priority classes:
//!
//! - `Realtime`: Always scheduled before batch and idle threads.
//!   Picked from `realtime_runq` in strict priority order.
//!   Interactive batch threads are promoted into this queue.
//! - `Batch`: Scheduled via a circular calendar queue that rotates
//!   on every tick, ensuring all threads get CPU time proportional
//!   to their priority.
//! - `Idle`: Only scheduled when both realtime and batch queues are empty.
//!
//! ## Interactivity Scoring
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
//! being assigned a static realtime priority.
//!
//! To prevent history from dominating forever, `sleep_time` and `run_time`
//! are decayed periodically by `sched_clamp_time`:
//! - Values are halved when their sum exceeds 120% of the 5-second cap.
//! - Values are reduced by 20% when the sum exceeds 5 seconds.
//! - Values are reset to (max, 1) when the sum exceeds 10 seconds.
//!
//! ## Calendar Queue
//!
//! The calendar queue is a circular array of `runqueues_n` (64) lists.
//! Two indices drive it:
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
//!
//! Timeshared (batch) threads do not preempt each other by default,
//! mirroring FreeBSD's default preemption threshold. Interactive threads
//! may still preempt non-interactive batch threads. Realtime threads
//! always preempt batch and idle threads.
//!
//! Remote preemption (sending an IPI to another CPU) is done lock-free
//! by reading a packed `current_thread_status` field that encodes the
//! running thread's priority and interactivity in a single atomic byte.
//!
//! ## Load Balancing
//!
//! Two mechanisms keep load distributed across CPUs:
//!
//! - **Work stealing**: When a CPU goes idle, it immediately attempts to
//!   steal a thread from the most loaded CPU.
//! - **Periodic balancing**: Every ~1 second (randomized with an LCG to
//!   avoid phase-locking with periodic threads), the bootstrap CPU moves
//!   threads from the most loaded CPU to the least loaded one.
//!
//! ## CPU Selection
//!
//! When enqueuing a thread, the target CPU is chosen in priority order:
//! 1. Last CPU the thread ran on, if it can be preempted or the thread is pinned.
//! 2. Least loaded CPU on which the thread would run immediately (preemptible).
//! 3. Least loaded CPU overall.
//!
//! See `sched_ule.c` in FreeBSD for the original implementation this is based on.
const std = @import("std");
const rtl = @import("rtl");
const config = @import("config");
const r = @import("root");
const ke = r.ke;
const ki = ke.private;

comptime {
    if (!@hasDecl(ki.impl, "send_resched_ipi")) @compileError("impl must provide send_resched_ipi");
}

const runqueues_n = 64;
const interactivity_threshold = 30;
const scaling_factor = 50;
const preempt_threshold = ke.Thread.Priority.realtime;
const balance_interval = @as(u64, config.CONFIG_BALANCE_INTERVAL);
const steal_threshold = 1;

var balance_timer: ke.Timer = undefined;
var balance_dpc: ke.Dpc = .init(balance);

// LCG values taken from FreeBSD.
var lcg = std.Random.lcg.Wrapping(u32).init(0, 69069, 5);

pub const RunQueue = struct {
    /// Bitmap of non-empty queues. A set bit represents a non-empty queue.
    status: u64,
    queues: [runqueues_n]rtl.List,
};

const ThreadStatus = packed struct(u8) {
    interactive: bool,
    priority: u7,
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
    /// Used to indicate to this CPU it can steal work
    steal_work: bool,
    /// Atomic byte for getting the current thread's status locklessly.
    /// 1 bit for thread interactivity, 7 for priority.
    current_thread_status: std.atomic.Value(ThreadStatus),
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
};

pub const percpu = ke.CpuLocal(PerCpu, undefined);

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

    cpu.queues_lock.release_no_ipl();
    cur.lock.acquire_no_ipl();

    if (cur != cpu.idle_thread and cur.state != .Blocked) {
        // Put it back in the queue.
        cpu.queues_lock.acquire_no_ipl();
        insert_in_queue(cpu, cur, false);
        cpu.queues_lock.release_no_ipl();
    }

    do_switch(cpu, cur, next);

    // cur.lock dropped
}

/// Called every time slice in DPC context.
pub fn clock(_: ?*anyopaque) void {
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
    }

    if (curtd.priority_class == .Batch) {
        // Update interactivity metrics.
        curtd.run_time += config.CONFIG_SCHED_TIMESLICE;

        clamp_time(curtd);
        recompute_priority(curtd);
    }

    if (cpu.next_thread != null) {
        // Another thread was already selected for preemption.
        return;
    }

    // Pick a new thread to run.
    const newtd = select_thread(curtd, cpu, false);

    // Ensure the timer gets reloaded.
    cpu.start_timer = true;
    cpu.next_thread = newtd;
}

/// Enqueue a thread.
pub fn enqueue(td: *ke.Thread) void {
    const ipl = td.lock.acquire();
    const cpu = pick_cpu(td);
    enqueue_on_cpu(cpu, td);
    td.lock.release(ipl);
}

/// Block the currently running thread.
pub fn block() void {
    const ipl = ke.ipl.raise(.Dispatch);
    const td = percpu.local().current_thread.?;

    td.lock.acquire_no_ipl();

    td.state = .Blocked;
    td.sleep_start = ke.clock.read_time();
    td.runq = null;

    yield(ke.cpu.current());

    // td lock released
    ke.ipl.lower(ipl);
}

/// Unblock a thread.
pub fn unblock(td: *ke.Thread) void {
    const ipl = td.lock.acquire();

    td.sleep_time = (ke.clock.read_time() - td.sleep_start) / std.time.ns_per_ms;

    if (td.sleep_time >= config.CONFIG_SCHED_TIMESLICE and td.priority_class == .Batch) {
        // If we have slept for more than a tick, update interactivity.
        clamp_time(td);
        recompute_priority(td);
    }

    // Enqueue the thread
    const cpu = pick_cpu(td);
    enqueue_on_cpu(cpu, td);

    td.lock.release(ipl);
}

export const sched_percpu_init linksection(r.percpu_init) = &init_cpu;

/// Initialize a CPU for use by the scheduler.
fn init_cpu() linksection(r.init) callconv(.c) void {
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
        .current_thread_status = .init(.{ .interactive = false, .priority = 0 }),
        .resched_dpc = .init(ki.sched.clock),
        .resched_timer = undefined,
        .start_timer = false,
        .preemption_reason = .None,
        .current_thread = null,
        .idle_thread = null,
        .next_thread = null,
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

        if (migrate) {
            // Find the first thread that is not pinned.
            while (td.pinned) {
                const entry = td.runq_link.next;

                td = @fieldParentPtr("runq_link", entry);

                // Every thread is pinned, go through another queue
                if (entry == &curr_queue.head) continue :qloop;
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

        if (migrate) {
            // Find the first thread that is not pinned.
            while (td.pinned) {
                const entry = td.runq_link.next;

                td = @fieldParentPtr("runq_link", entry);

                // Every thread is pinned, go through another queue
                if (entry == &curr_queue.head) continue :qloop;
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

    if (!(migrate and td.pinned)) {
        // We can safely remove it.
        td.runq_link.remove();
    }

    return td;
}

fn insert_in_list(list: *rtl.List, link: *rtl.List.Entry, head: bool) void {
    if (head) list.insert_head(link) else list.insert_tail(link);
}

// Insert a thread into its respective queue.
fn insert_in_queue(cpu: *PerCpu, td: *ke.Thread, head: bool) void {
    std.debug.assert(cpu.queues_lock.is_locked());

    if (td.priority_class == .Realtime or td.interactive) {
        // Insert in realtime queue.
        cpu.realtime_queue.status |=
            (@as(u64, 1) << @intCast(td.priority));

        insert_in_list(&cpu.realtime_queue.queues[td.priority], &td.runq_link, head);
        td.runq = &cpu.realtime_queue;
        td.runq_idx = @intCast(td.priority);
    } else if (td.priority_class == .Batch) {
        // Insert in calendar queue.
        // The insertion index is determined by insidx and the the priority of the thread,
        // higher priority threads will be put closer to insidx, which ensures that they are ran more frequently.
        const idx = (cpu.insidx + (ke.Thread.Priority.high_batch - td.priority)) % runqueues_n;

        td.runq_idx = @intCast(idx);
        cpu.calendar_queue.status |= (@as(u64, 1) << @intCast(idx));

        insert_in_list(&cpu.calendar_queue.queues[idx], &td.runq_link, head);
        td.runq = &cpu.calendar_queue;
    } else {
        // Insert in idle queue.
        insert_in_list(&cpu.idle_queue, &td.runq_link, head);
        td.runq = null;
        td.runq_idx = 0;
    }

    td.state = .Ready;
    _ = cpu.load.fetchAdd(1, .monotonic);
}

// Remove a thread from a queue.
fn remove_from_queue(cpu: *PerCpu, td: *ke.Thread) void {
    std.debug.assert(td.lock.is_locked());
    std.debug.assert(cpu.queues_lock.is_locked());

    // Decrease load.
    cpu.load.fetchSub(1, .monotonic);

    // Remove the thread from its queue.
    td.runq_link.remove();

    if (td.runq) |rq| {
        if (rq.queues[td.runq_idx].is_empty()) {
            // Clear the bit.
            rq.status &= ~(@as(u64, 1) << @intCast(td.runq_idx));
        }
    }
}

// Update recent history for a thread.
fn clamp_time(td: *ke.Thread) void {
    const max = 5 * std.time.ms_per_s; // 5 seconds
    const sum = td.run_time + td.sleep_time;

    if (sum < max) return;

    if (sum > max * 2) {
        // History is way out of range (>10s), hard reset.
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

    // History is slightly out of range (5s-6s), gentle 20% decay.
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
    score = @intCast(signed_score);

    return score;
}

// Recompute the priority for a thread.
fn recompute_priority(td: *ke.Thread) void {

    // Priority is computed only for time-shared (batch) thread based on
    // interactivity and nice. If the thread is determined interactive, it is
    // effectively promoted to real-time with a lower priority than actual
    // real-time threads. If the thread is determined non-interactive,
    // priority is calculated based on recent CPU usage and nice.
    const score = interactive_score(td);

    if (score < interactivity_threshold) {
        // Choose a priority based on score, the lower the score,
        // the higher the priority it will be.
        // This is a simple formula I came up with that is probably good enough.
        td.priority = @intCast(ke.Thread.Priority.interactive + ((interactivity_threshold - score) / 4));
        td.interactive = true;

        return;
    }

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

    td.priority = @intCast(std.math.clamp(
        raw,
        ke.Thread.Priority.low_batch,
        ke.Thread.Priority.high_batch,
    ));
    td.interactive = false;
}

// Return whether or not a thread with given priority and interactivity should get preempted by `td`.
fn should_prio_preempt(td: *ke.Thread, other_prio: u8, other_interactive: bool) bool {
    const class = ke.Thread.Priority.class_from_prio(other_prio);

    if (class == .Idle) {
        return true;
    }

    if (class == .Batch and !other_interactive and td.interactive) {
        // Interactive threads always preempt batch non-interactive ones.
        return true;
    }

    // Preempt if the priority exceeds the preemption threshold (i.e the thread is real-time)
    // or if the thread is interactive.
    // Interactive threads may still preempt each other based on interactivity.
    if ((td.priority >= preempt_threshold or td.interactive) and td.priority > other_prio) {
        return true;
    }

    return false;
}

// Return whether or not `td` should preempt `cur`.
// This is called with the current CPU's queue lock held.
fn should_preempt(td: *ke.Thread, cur: *ke.Thread) bool {
    return should_prio_preempt(td, cur.priority, cur.interactive);
}

// Return whether or not `td` should preempt the thread running on `cpu`.
// This is done in a lock-free manner.
fn should_preempt_cpu(td: *ke.Thread, cpu: *PerCpu) bool {
    const status = cpu.current_thread_status.load(.monotonic);
    return should_prio_preempt(td, status.priority, status.interactive);
}

// Enqueue a thread on a CPU.
fn enqueue_on_cpu(c: u32, td: *ke.Thread) void {
    const cpu = percpu.remote(c);
    cpu.queues_lock.acquire_no_ipl();

    defer cpu.queues_lock.release_no_ipl();

    if (cpu.current_thread == null or should_preempt(td, cpu.current_thread.?)) {
        // We can preempt the current thread, first check whether or not there
        // is already a next thread selected, and if we can preempt it.

        const next = cpu.next_thread;
        var can_preempt = true;

        if (next) |n| {
            if (should_preempt(td, n)) {
                // This thread can preempt the next thread,
                // put the next thread back into a queue as the first element.
                insert_in_queue(cpu, n, true);
            } else {
                // The next thread is higher priority, we can't preempt it.
                can_preempt = false;
            }
        }

        if (can_preempt) {
            // Preempt the CPU.
            cpu.next_thread = td;
            cpu.preemption_reason = .HigherPriority;

            ki.ipl.set_softint_pending(c, .Dispatch);

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

    if (td.last_cpu) |cpu| {
        const sched_cpu = percpu.remote(cpu);
        if (should_preempt_cpu(td, sched_cpu) or td.pinned) return cpu;
    }

    // Check all CPUs, keeping track of the least loaded one overall and the least loaded preemptible one.
    var least: ?u32 = null;
    var least_preempt: ?u32 = null;

    for (0..ke.ncpus) |i| {
        const cpu: u32 = @truncate(i);
        const data = percpu.remote(cpu);

        if (least == null or data.load.load(.monotonic) < percpu.remote(least.?).load.load(.monotonic)) {
            least = cpu;
        }

        if (should_preempt_cpu(td, data)) {
            if (least_preempt == null or data.load.load(.monotonic) < percpu.remote(least_preempt.?).load.load(.monotonic)) {
                least_preempt = cpu;
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
        return td;
    }

    // Nothing lower can preempt this thread.
    if (cur != null and (cur.?.priority_class == .Realtime or cur.?.interactive)) {
        return null;
    }

    // Then try picking a batch thread.
    if (pick_batch_thread(cpu, migrate)) |td| {
        _ = cpu.load.fetchSub(1, .monotonic);
        return td;
    }

    if (cur != null and cur.?.priority_class == .Idle) {
        // Idle threads don't preempt each other
        return null;
    }

    // Finally try picking from the idle queue.
    if (pick_idle_thread(cpu, migrate)) |td| {
        _ = cpu.load.fetchSub(1, .monotonic);
        return td;
    }

    // Nothing to run.
    return null;
}

// Execute a context switch on `cpu`.
fn do_switch(cpu: *PerCpu, cur: *ke.Thread, next: *ke.Thread) void {
    next.state = .Running;
    cpu.current_thread = next;
    next.last_cpu = ke.cpu.current();

    // Stash thread status.
    cpu.current_thread_status.store(.{ .interactive = next.interactive, .priority = @intCast(next.priority) }, .monotonic);

    // Do machine-dependent switch.
    cur.context.switch_to(&next.context);
}

// Yield on `cpu`
fn yield(cpu: u32) void {
    const sched_cpu = percpu.remote(cpu);

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

    sched_cpu.queues_lock.release_no_ipl();

    // Switch into the thread.
    do_switch(sched_cpu, cur.?, next.?);

    // cur lock dropped
}

fn find_most_loaded(exclude: ?*ke.CpuMask) ?u32 {
    var most: ?u32 = null;
    var most_load: usize = 0;
    var equal = true;

    for (0..ke.ncpus) |i| {
        if (exclude) |mask| {
            if (mask.is_set(i)) {
                continue;
            }
        }

        const cpu = percpu.remote(@truncate(i));
        const load = cpu.load.load(.monotonic);

        if (most == null) {
            most = @truncate(i);
            most_load = load;
        } else if (load > most_load) {
            most = @truncate(i);
            most_load = load;
            equal = false;
        } else if (load < most_load) {
            equal = false;
        }
    }

    if (equal) {
        // All CPUs have the same load, return null to indicate this.
        return null;
    }

    return most;
}

fn find_least_loaded(exclude: ?*ke.CpuMask) ?u32 {
    var least: ?u32 = null;
    var least_load: usize = 0;
    var equal = true;

    for (0..ke.ncpus) |i| {
        if (exclude) |mask| {
            if (mask.is_set(i)) {
                continue;
            }
        }

        const cpu = percpu.remote(@truncate(i));
        const load = cpu.load.load(.monotonic);

        if (least == null) {
            least = @truncate(i);
            least_load = load;
        } else if (load < least_load) {
            least = @truncate(i);
            least_load = load;
            equal = false;
        } else if (load > least_load) {
            equal = false;
        }
    }

    if (equal) {
        // All CPUs have the same load, return null to indicate this.
        return null;
    }

    return least;
}

fn steal_thread_from_cpu(cpu: *PerCpu) ?*ke.Thread {
    cpu.queues_lock.acquire_no_ipl();

    const td = select_thread(null, cpu, true);

    cpu.queues_lock.release_no_ipl();

    return td;
}

fn steal_work(cpu: u32) ?*ke.Thread {
    const most = find_most_loaded(null);

    if (most == cpu) {
        // We're the most loaded CPU, nothing to steal.
        return null;
    }

    if (most) |other| {
        const sched_other = percpu.remote(other);
        if (sched_other.load.load(.monotonic) < steal_threshold) {
            return null;
        }

        return steal_thread_from_cpu(sched_other);
    }

    return null;
}

/// Idle loop for a CPU. Must be set up in the idle thread.
pub fn idle(_: ?*anyopaque) noreturn {
    while (true) {
        const cpu = percpu.local();
        const cpu_id = ke.cpu.current();

        if (cpu.steal_work) {
            // When first going idle, try stealing work from the most loaded CPU.
            cpu.steal_work = false;

            const ipl = ke.ipl.raise(.Dispatch);

            // Steal a thread.
            if (steal_work(cpu_id)) |td| {
                // Enqueue it on this CPU.
                enqueue_on_cpu(cpu_id, td);
            }

            ke.ipl.lower(ipl);
        }

        std.atomic.spinLoopHint();
    }
}

/// Called every second to balance work between CPUs on CPU0.
/// Takes a thread from the most loaded CPU and puts it on the least loaded one.
fn balance(_: ?*anyopaque) void {
    var high_mask = ke.CpuMask.empty();
    var low_mask: ke.CpuMask = undefined;

    while (true) {
        const high = find_most_loaded(&high_mask);

        if (high == null or percpu.remote(high.?).load.load(.monotonic) == 0) {
            // No highest loaded CPU.
            break;
        }

        // Don't steal from this CPU again.
        high_mask.set(high.?);
        low_mask = high_mask;

        if (high_mask.is_full()) {
            // All CPUs are masked, nothing to steal.
            break;
        }

        const low = find_least_loaded(&low_mask);

        if (low == null) {
            // No lowest loaded CPU.
            break;
        }

        // Steal a thread from the high CPU and put it on the low CPU.
        const sched_high = percpu.remote(high.?);
        const td = steal_thread_from_cpu(sched_high);

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
