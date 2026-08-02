//! Turnstile / priority inheritance test.
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const ps = r.ps;

const prio_low: u8 = 4;
const prio_mid: u8 = 16;
const prio_high: u8 = 30;

const nmutexes = 8;
const max_stress = 32;

var m1: ke.Mutex = undefined;
var m2: ke.Mutex = undefined;

var low_td: *ps.Thread = undefined;
var mid_td: *ps.Thread = undefined;
var high_td: *ps.Thread = undefined;

var low_locked = std.atomic.Value(bool).init(false);
var release_low = std.atomic.Value(bool).init(false);
var release_mid = std.atomic.Value(bool).init(false);
var finished = std.atomic.Value(bool).init(false);
var chain_done = std.atomic.Value(usize).init(0);

var locks: [nmutexes]ke.Mutex = undefined;
var stress_tds: [max_stress]*ps.Thread = undefined;
var stress_prio: [max_stress]u8 = undefined;
var nstress: usize = 0;

var paused = std.atomic.Value(bool).init(false);
var parked = std.atomic.Value(usize).init(0);
var acquisitions = std.atomic.Value(u64).init(0);

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
    _ = ke.wait.wait_one(&timer.hdr, null) catch unreachable;
}

fn wait_flag(flag: *std.atomic.Value(bool)) void {
    while (!flag.load(.acquire)) delay_ms(1);
}

fn cur_prio(td: *ps.Thread) u8 {
    return @atomicLoad(u8, &td.kern.priority, .monotonic);
}

fn cur_inherited(td: *ps.Thread) u8 {
    return @atomicLoad(u8, &td.kern.inherited_prio, .monotonic);
}

/// Poll until `td` reaches priority `want`, panic on timeout.
fn expect_prio(td: *ps.Thread, want: u8, what: []const u8) void {
    for (0..2000) |_| {
        if (cur_prio(td) == want) return;
        delay_ms(1);
    }

    std.log.err("pi: {s}: want priority {}, got {}", .{ what, want, cur_prio(td) });
    @panic("pi: priority check failed");
}

fn chain_low(_: ?*anyopaque) void {
    m1.acquire();
    low_locked.store(true, .release);
    wait_flag(&release_low);
    m1.release();

    _ = chain_done.fetchAdd(1, .release);
    wait_flag(&finished);
    ps.thread.exit();
}

fn chain_mid(_: ?*anyopaque) void {
    m2.acquire();
    m1.acquire();
    m1.release();
    wait_flag(&release_mid);
    m2.release();

    _ = chain_done.fetchAdd(1, .release);
    wait_flag(&finished);
    ps.thread.exit();
}

fn chain_high(_: ?*anyopaque) void {
    m2.acquire();
    m2.release();

    _ = chain_done.fetchAdd(1, .release);
    wait_flag(&finished);
    ps.thread.exit();
}

fn spawn(prio: u8, entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) *ps.Thread {
    const t = ps.thread.create_kernel(prio, entry, arg) catch @panic("oom");
    ke.sched.enqueue(&t.kern);
    return t;
}

fn chain_test() void {
    m1 = .init();
    m2 = .init();

    low_td = spawn(prio_low, &chain_low, null);
    wait_flag(&low_locked);

    // Mid takes M2 then blocks on M1, donating to low.
    mid_td = spawn(prio_mid, &chain_mid, null);
    expect_prio(low_td, prio_mid, "low boosted by mid");

    // High blocks on M2; the donation must propagate through mid down to low.
    high_td = spawn(prio_high, &chain_high, null);
    expect_prio(mid_td, prio_high, "mid boosted by high");
    expect_prio(low_td, prio_high, "boost propagated to low");

    release_low.store(true, .release);
    expect_prio(low_td, prio_low, "low boost revoked after release");
    expect_prio(mid_td, prio_high, "mid still boosted while high waits");

    release_mid.store(true, .release);
    expect_prio(mid_td, prio_mid, "mid boost revoked after release");

    while (chain_done.load(.acquire) != 3) delay_ms(1);

    for ([_]*ps.Thread{ low_td, mid_td, high_td }) |td| {
        if (cur_inherited(td) != 0) @panic("pi: leftover inherited priority after chain test");
    }

    std.log.info("turnstile: chain test passed", .{});
    finished.store(true, .release);
}

fn stress(param: ?*anyopaque) void {
    const id = @intFromPtr(param.?) - 1;
    var seed = (ke.time.read_time() ^ (id *% 0x9e3779b97f4a7c15)) | 1;
    var iter: u64 = 0;

    while (true) : (iter += 1) {
        if (paused.load(.acquire)) {
            _ = parked.fetchAdd(1, .acq_rel);
            while (paused.load(.acquire)) delay_ms(1);
            _ = parked.fetchSub(1, .acq_rel);
        }

        const first: usize = @intCast(rand(&seed) % nmutexes);
        const last = @min(first + 1 + rand(&seed) % 3, nmutexes);

        for (first..last) |i| locks[i].acquire();

        if (rand(&seed) % 16 == 0) {
            delay_ms(1);
        } else {
            for (0..rand(&seed) % 512) |_| std.atomic.spinLoopHint();
        }

        var i = last;
        while (i > first) : (i -= 1) locks[i - 1].release();

        if (cur_prio(stress_tds[id]) < stress_prio[id]) {
            @panic("pi: priority dropped below base");
        }

        _ = acquisitions.fetchAdd(1, .monotonic);

        if (iter % 64 == 0) delay_ms(1);
    }
}

/// Park all threads, then
/// verify every donation has been revoked.
fn quiesce_check() void {
    paused.store(true, .release);

    var spins: usize = 0;
    while (parked.load(.acquire) != nstress) : (spins += 1) {
        if (spins > 10_000) @panic("pi: stress threads failed to park");
        delay_ms(1);
    }

    for (0..nstress) |i| {
        if (cur_prio(stress_tds[i]) != stress_prio[i] or cur_inherited(stress_tds[i]) != 0) {
            std.log.err("pi: thread {}: base {}, prio {}, inherited {}", .{
                i,
                stress_prio[i],
                cur_prio(stress_tds[i]),
                cur_inherited(stress_tds[i]),
            });
            @panic("pi: boost not revoked at quiescence");
        }
    }

    paused.store(false, .release);
    while (parked.load(.acquire) != 0) delay_ms(1);
}

pub fn start(_: ?*anyopaque) void {
    chain_test();

    for (&locks) |*l| l.* = .init();

    nstress = @max(4, @min(ke.ncpus * 2, max_stress));

    for (0..nstress) |i| {
        const prio: u8 = @intCast(2 + (i * 5) % 29);
        stress_prio[i] = prio;

        const t = ps.thread.create_kernel(prio, &stress, @ptrFromInt(i + 1)) catch @panic("oom");
        stress_tds[i] = t;
        ke.sched.enqueue(&t.kern);
    }

    while (true) {
        delay_ms(2000);
        quiesce_check();
        std.log.info("turnstile: acquisitions: {}, quiescence OK", .{acquisitions.load(.monotonic)});
    }
}
