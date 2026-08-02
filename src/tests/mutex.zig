//! Mutex stress test.
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const ps = r.ps;

const nmutexes = 8;
const max_threads = 32;

const Guarded = struct {
    mutex: ke.Mutex,
    guard: usize,
    count: u64,
};

var locks: [nmutexes]Guarded = undefined;
var totals: [max_threads]u64 = undefined;
var tds: [max_threads]*ps.Thread = undefined;
var is_parked: [max_threads]std.atomic.Value(bool) = undefined;
var nthreads: usize = 0;

var paused = std.atomic.Value(bool).init(false);
var parked = std.atomic.Value(usize).init(0);

fn rand(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn delay_ms(ms: usize) void {
    var timer: ke.Timer = undefined;
    timer.init();
    ke.timer.set(&timer, std.time.ns_per_ms * ms, .{});
    _ = ke.wait.wait_one(&timer.hdr, .{}) catch unreachable;
}

fn worker(param: ?*anyopaque) void {
    const id = @intFromPtr(param.?) - 1;
    var seed = (ke.time.read_time() ^ (id *% 0x9e3779b97f4a7c15)) | 1;
    var iter: u64 = 0;

    while (true) : (iter += 1) {
        if (paused.load(.acquire)) {
            _ = parked.fetchAdd(1, .acq_rel);
            is_parked[id].store(true, .release);
            while (paused.load(.acquire)) delay_ms(1);
            is_parked[id].store(false, .release);
            _ = parked.fetchSub(1, .acq_rel);
        }

        const first: usize = @intCast(rand(&seed) % nmutexes);
        const last = @min(first + 1 + rand(&seed) % 2, nmutexes);

        for (first..last) |i| locks[i].mutex.acquire();

        for (first..last) |i| {
            if (@atomicLoad(usize, &locks[i].guard, .monotonic) != 0) {
                @panic("mutex: guard set on entry, exclusion violated");
            }

            @atomicStore(usize, &locks[i].guard, id + 1, .monotonic);
        }
        if (rand(&seed) % 16 == 0) {
            delay_ms(1);
        } else {
            for (0..rand(&seed) % 256) |_| std.atomic.spinLoopHint();
        }

        for (first..last) |i| {
            const c = @atomicLoad(u64, &locks[i].count, .monotonic);

            for (0..rand(&seed) % 64) |_| std.atomic.spinLoopHint();

            @atomicStore(u64, &locks[i].count, c + 1, .monotonic);

            if (@atomicLoad(usize, &locks[i].guard, .monotonic) != id + 1) {
                @panic("mutex: guard changed while held, exclusion violated");
            }

            @atomicStore(usize, &locks[i].guard, 0, .monotonic);
        }

        var i = last;
        while (i > first) : (i -= 1) locks[i - 1].mutex.release();

        totals[id] += last - first;

        if (iter % 64 == 0) delay_ms(1);
    }
}

fn dump_stuck_workers() void {
    for (0..nthreads) |i| {
        if (is_parked[i].load(.acquire)) continue;

        const td = &tds[i].kern;
        const waiting = @atomicLoad(?*anyopaque, &td.waiting_on, .monotonic);
        var lock_idx: isize = -1;

        for (&locks, 0..) |*l, j| {
            if (waiting == @as(?*anyopaque, @ptrCast(&l.mutex))) lock_idx = @intCast(j);
        }

        std.log.err("mutex: worker {} stuck: state {s}, prio {}/{}, inherited {}, waiting_on {x} (lock {})", .{
            i,
            @tagName(td.state.load(.monotonic)),
            @atomicLoad(u8, &td.priority, .monotonic),
            @atomicLoad(u8, &td.base_priority, .monotonic),
            @atomicLoad(u8, &td.inherited_prio, .monotonic),
            if (waiting) |w| @intFromPtr(w) else 0,
            lock_idx,
        });
    }
}

/// Park all workers (they hold nothing at the loop top), then verify that
/// no increments were lost and no guard is stuck.
fn quiesce_verify() u64 {
    paused.store(true, .release);

    var spins: usize = 0;
    while (parked.load(.acquire) != nthreads) : (spins += 1) {
        if (spins > 10_000) {
            dump_stuck_workers();
            @panic("mutex: workers failed to park");
        }
        delay_ms(1);
    }

    var counted: u64 = 0;
    var expected: u64 = 0;

    for (&locks) |*l| {
        if (@atomicLoad(usize, &l.guard, .monotonic) != 0) {
            @panic("mutex: guard set at quiescence");
        }

        counted += @atomicLoad(u64, &l.count, .monotonic);
    }

    for (0..nthreads) |i| expected += @atomicLoad(u64, &totals[i], .monotonic);

    if (counted != expected) {
        std.log.err("mutex: lost updates: counted {}, expected {}", .{ counted, expected });
        @panic("mutex: lost updates, exclusion or ordering violated");
    }

    paused.store(false, .release);
    while (parked.load(.acquire) != 0) delay_ms(1);

    return counted;
}

pub fn start(_: ?*anyopaque) void {
    for (&locks) |*l| {
        l.mutex = .init();
        l.guard = 0;
        l.count = 0;
    }

    nthreads = @max(4, @min(ke.ncpus * 2, max_threads));

    for (0..nthreads) |i| {
        totals[i] = 0;
        is_parked[i] = .init(false);

        const prio: u8 = @intCast(2 + (i * 5) % 29);
        const t = ps.thread.create_kernel(prio, &worker, @ptrFromInt(i + 1)) catch @panic("oom");
        tds[i] = t;
        ke.sched.enqueue(&t.kern);
    }

    while (true) {
        delay_ms(2000);

        const count = quiesce_verify();
        std.log.info("mutex: {} sections, no lost updates", .{count});
    }
}
