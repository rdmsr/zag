//! Preemptible SMR priority-inheritance test.
//! Same shape as the SMR stress test, but the read sections
//! are long enough to be preempted and the pollers run at a high priority so
//! they end up blocked on the stalled readers.
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const ps = r.ps;
const rtl = @import("rtl");

const ki = ke.private;

const prio_reader: u8 = 4;
const prio_writer: u8 = 6;
const prio_poller: u8 = 30;

const nslots = 128;
const obj_words = 8;
const reads_per_section = 16;
const readers_per_cpu = 4;
const section_us = 3000;

const Object = struct {
    vals: [obj_words]u64,
};

var dom: *ke.smr.Domain = undefined;
var zone: mm.zone.Zone = undefined;

var slots = [_]std.atomic.Value(?*Object){.init(null)} ** nslots;

var next_val = std.atomic.Value(u64).init(1);
var reads = std.atomic.Value(u64).init(0);
var writes = std.atomic.Value(u64).init(0);
var polls = std.atomic.Value(u64).init(0);

/// Number of pairs seen boosted.
var boosts_seen = std.atomic.Value(u64).init(0);
/// Largest number of readers ever seen stalled on a single CPU at once.
var max_co_stalled = std.atomic.Value(usize).init(0);

var paused = std.atomic.Value(bool).init(false);
var parked = std.atomic.Value(usize).init(0);
var nworkers: usize = 0;

var reader_tds: [64]*ps.Thread = undefined;
var nreaders: usize = 0;

fn rand(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn seed_from(param: ?*anyopaque) u64 {
    return (ke.time.read_time() ^ (@intFromPtr(param.?) *% 0x9e3779b97f4a7c15)) | 1;
}

fn delay_ms(ms: usize) void {
    var timer: ke.Timer = undefined;
    timer.init();
    ke.timer.set(&timer, std.time.ns_per_ms * ms, .{});
    _ = ke.wait.wait_one(&timer.hdr, .{}) catch unreachable;
}

/// Park here while the checker is verifying quiescence. Only ever called
/// outside a read section.
fn park_point() void {
    if (!paused.load(.acquire)) return;

    _ = parked.fetchAdd(1, .acq_rel);
    while (paused.load(.acquire)) delay_ms(1);
    _ = parked.fetchSub(1, .acq_rel);
}

fn spin_us(us: u64) void {
    const began = ke.time.read_time();
    while (ke.time.read_time() - began < us * std.time.ns_per_us) {
        std.atomic.spinLoopHint();
    }
}

fn reader(param: ?*anyopaque) void {
    var seed = seed_from(param);

    while (true) {
        park_point();

        var tracker: ki.smr.Tracker = undefined;
        ki.smr.enter_preempt(dom, &tracker);
        var done: u64 = 0;

        for (0..reads_per_section) |_| {
            const idx: usize = @intCast(rand(&seed) % nslots);
            const obj = slots[idx].load(.acquire) orelse continue;

            const v = @atomicLoad(u64, &obj.vals[0], .monotonic);

            for (1..obj_words) |i| {
                if (@atomicLoad(u64, &obj.vals[i], .monotonic) != v) {
                    @panic("smr pi: torn read, object reused during read section");
                }
            }

            done += 1;
        }

        // Stay in the section well past a timeslice so we get preempted and
        // land on the stalled list. A blocked poller must boost us out of here.
        spin_us(section_us);

        ki.smr.exit_preempt(dom, &tracker);

        _ = reads.fetchAdd(done, .monotonic);
    }
}

fn writer(param: ?*anyopaque) void {
    var seed = seed_from(param);

    while (true) {
        park_point();

        const idx: usize = @intCast(rand(&seed) % nslots);
        var new_obj: ?*Object = null;

        if (rand(&seed) % 8 != 0) {
            if (zone.alloc(.{})) |buf| {
                const obj: *Object = @ptrCast(@alignCast(buf));
                const v = next_val.fetchAdd(1, .monotonic);

                for (&obj.vals) |*w| {
                    @atomicStore(u64, w, v, .monotonic);
                    std.atomic.spinLoopHint();
                }

                new_obj = obj;
            } else |_| {}
        }

        const old = slots[idx].swap(new_obj, .acq_rel);

        if (old) |o| {
            zone.free(o);
        }

        _ = writes.fetchAdd(1, .monotonic);

        ke.sched.yield();
    }
}

fn poller(_: ?*anyopaque) void {
    while (true) {
        park_point();

        _ = ke.smr.poll(dom, ke.smr.advance(dom), true);

        _ = polls.fetchAdd(1, .monotonic);

        ke.sched.yield();
    }
}

fn cur_prio(td: *ke.Thread) u8 {
    return @atomicLoad(u8, &td.priority, .monotonic);
}

fn cur_inherited(td: *ke.Thread) u8 {
    return @atomicLoad(u8, &td.inherited_prio, .monotonic);
}

/// Highest priority among the threads blocked on `ts`, or null if none.
fn blocked_prio(ts: *ki.turnstile.Turnstile) ?u8 {
    var best: ?u8 = null;

    for (&ts.queues) |*q| {
        var it = q.iterator();
        while (it.next()) : (it.advance()) {
            const w: *ki.turnstile.Waiter = @fieldParentPtr("link", it.get());
            best = @max(best orelse 0, cur_prio(w.thread));
        }
    }

    return best;
}

/// Walk one domain CPU and check every stalled reader against the priority of
/// whoever is blocked waiting for them.
fn check_cpu(cpu: *ke.smr.Cpu) void {
    const ipl = ke.ipl.raise(.Dispatch);
    cpu.stall_lock.acquire_no_ipl();

    const turnstile = ki.turnstile.lookup(cpu);

    if (turnstile) |ts| {
        if (blocked_prio(ts)) |want| {
            var stalled: usize = 0;
            var it = cpu.stalled.iterator();

            while (it.next()) : (it.advance()) {
                const owner: *ki.turnstile.Owner = @fieldParentPtr("link", it.get());
                const tracker: *ki.smr.Tracker = @fieldParentPtr("owner", owner);
                const td = tracker.owner.thread;
                stalled += 1;

                if (cur_inherited(td) < want or cur_prio(td) < want) {
                    std.log.err(
                        "smr pi: stalled reader {} of this cpu: thread {*} prio {}, inherited {}, want {}",
                        .{ stalled, td, cur_prio(td), cur_inherited(td), want },
                    );
                    @panic("smr pi: stalled reader not boosted to waiter priority");
                }
            }

            _ = boosts_seen.fetchAdd(stalled, .monotonic);

            var max = max_co_stalled.load(.monotonic);
            while (stalled > max) {
                max = max_co_stalled.cmpxchgWeak(max, stalled, .monotonic, .monotonic) orelse break;
            }
        }
    }

    ki.turnstile.exit(cpu);
    cpu.stall_lock.release_no_ipl();
    ke.ipl.lower(ipl);
}

fn check_boosts() void {
    for (0..ke.ncpus) |i| check_cpu(&dom.cpus[i]);
}

/// Park every worker and verify that no donation survived.
fn quiesce_check() void {
    paused.store(true, .release);

    var spins: usize = 0;
    while (parked.load(.acquire) != nworkers) : (spins += 1) {
        if (spins > 10_000) @panic("smr pi: workers failed to park");
        delay_ms(1);
    }

    for (0..ke.ncpus) |i| {
        const cpu = &dom.cpus[i];
        const ipl = ke.ipl.raise(.Dispatch);
        cpu.stall_lock.acquire_no_ipl();

        if (!cpu.stalled.is_empty()) @panic("smr pi: stalled readers left at quiescence");
        if (cpu.stall_seq.load(.monotonic) != ke.smr.seq_invalid) {
            @panic("smr pi: stall sequence not reset at quiescence");
        }

        cpu.stall_lock.release_no_ipl();
        ke.ipl.lower(ipl);
    }

    for (0..nreaders) |i| {
        const td = &reader_tds[i].kern;
        const base = @atomicLoad(u8, &td.base_priority, .monotonic);

        if (cur_inherited(td) != 0 or cur_prio(td) != base) {
            std.log.err("smr pi: reader {}: prio {}, inherited {}, base {}", .{
                i,
                cur_prio(td),
                cur_inherited(td),
                base,
            });
            @panic("smr pi: boost not revoked at quiescence");
        }
    }

    paused.store(false, .release);
    while (parked.load(.acquire) != 0) delay_ms(1);
}

fn spawn(prio: u8, entry: *const fn (?*anyopaque) void, id: usize) *ps.Thread {
    const t = ps.thread.create_kernel(prio, entry, @ptrFromInt(id + 1)) catch @panic("oom");
    ke.sched.enqueue(&t.kern);
    return t;
}

pub fn start(_: ?*anyopaque) void {
    std.log.info("{}", .{@sizeOf(ki.smr.Tracker)});

    dom = mm.zone.smr_domain_create(true) catch @panic("failed to create SMR domain");
    zone.init("smr-pi", @sizeOf(Object), .{
        .alignment = @alignOf(Object),
        .smr = dom,
    });

    nreaders = @min(ke.ncpus * readers_per_cpu, reader_tds.len);
    const nwriters = @max(1, ke.ncpus / 2);
    const npollers = @max(1, ke.ncpus / 2);

    nworkers = nreaders + nwriters + npollers;

    var id: usize = 0;

    for (0..nreaders) |i| {
        reader_tds[i] = spawn(prio_reader, &reader, id);
        id += 1;
    }

    for (0..nwriters) |_| {
        _ = spawn(prio_writer, &writer, id);
        id += 1;
    }

    for (0..npollers) |_| {
        _ = spawn(prio_poller, &poller, id);
        id += 1;
    }

    var round: usize = 0;

    while (true) : (round += 1) {
        for (0..50) |_| {
            check_boosts();
            delay_ms(15);
        }

        quiesce_check();

        const seen = boosts_seen.load(.monotonic);
        const max_co = max_co_stalled.load(.monotonic);

        std.log.info("smr pi: reads: {}, writes: {}, polls: {}, boosts seen: {}, max co-stalled: {}", .{
            reads.load(.monotonic),
            writes.load(.monotonic),
            polls.load(.monotonic),
            seen,
            max_co,
        });

        if (round >= 2) {
            if (seen == 0) @panic("smr pi: never observed a boosted stalled reader");
            if (max_co < 2) @panic("smr pi: never observed two readers stalled on one cpu");
        }
    }
}
