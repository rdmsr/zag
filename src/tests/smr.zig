//! SMR stress test.
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const ps = r.ps;

const ki = ke.private;

const nslots = 128;
const obj_words = 8;
const reads_per_section = 16;

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

fn rand(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn seed_from(param: ?*anyopaque) u64 {
    return (ke.time.read_time().value ^ (@intFromPtr(param.?) *% 0x9e3779b97f4a7c15)) | 1;
}

fn delay_ms(ms: usize) void {
    var timer: ke.Timer = undefined;
    timer.init();
    ke.timer.set(&timer, .init(std.time.ns_per_ms * ms), .{});
    _ = ke.wait.wait_one(&timer.hdr, "sleep", .{}) catch unreachable;
}

fn reader(param: ?*anyopaque) void {
    var seed = seed_from(param);
    var iter: u64 = 0;

    while (true) : (iter += 1) {
        const ipl = ki.smr.enter(dom);
        var done: u64 = 0;

        for (0..reads_per_section) |_| {
            const idx: usize = @intCast(rand(&seed) % nslots);
            const obj = slots[idx].load(.acquire) orelse continue;

            const v = @atomicLoad(u64, &obj.vals[0], .monotonic);

            for (1..obj_words) |i| {
                if (@atomicLoad(u64, &obj.vals[i], .monotonic) != v) {
                    @panic("smr stress: torn read, object reused during read section");
                }
            }

            done += 1;
        }

        ki.smr.exit(dom, ipl);

        _ = reads.fetchAdd(done, .monotonic);

        if (iter % 512 == 0) ke.sched.yield();
    }
}

fn writer(param: ?*anyopaque) void {
    var seed = seed_from(param);
    var iter: u64 = 0;

    while (true) : (iter += 1) {
        const idx: usize = @intCast(rand(&seed) % nslots);
        var new_obj: ?*Object = null;

        // Every so often publish null instead to exercise empty slots.
        if (rand(&seed) % 8 != 0) {
            if (zone.alloc(.{})) |buf| {
                const obj: *Object = @ptrCast(@alignCast(buf));
                const v = next_val.fetchAdd(1, .monotonic);

                // Fill word by word with pauses so a reader still holding
                // this memory has a wide window to observe a torn state.
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

        if (iter % 256 == 0) ke.sched.yield();
    }
}

fn poller(_: ?*anyopaque) void {
    var iter: u64 = 0;

    while (true) : (iter += 1) {
        if (iter % 2 == 0) {
            _ = ke.smr.poll(dom, ke.smr.advance(dom), true);
        } else {
            const goal = ke.smr.deferred_advance(dom);

            if (!ke.smr.poll(dom, goal, false)) {
                ke.smr.deferred_advance_commit(dom, goal);
                _ = ke.smr.poll(dom, goal, true);
            }
        }

        _ = polls.fetchAdd(1, .monotonic);

        ke.sched.yield();
    }
}

fn spawn(entry: *const fn (?*anyopaque) void, id: usize) void {
    const t = ps.thread.create_kernel(.Default, entry, @ptrFromInt(id + 1)) catch @panic("oom");
    ke.sched.enqueue(&t.kern);
}

pub fn start(_: ?*anyopaque) void {
    dom = mm.zone.smr_domain_create(false) catch @panic("failed to create SMR domain");
    zone.init("smr-stress", @sizeOf(Object), .{
        .alignment = @alignOf(Object),
        .smr = dom,
    });

    const nreaders = ke.ncpus;
    const nwriters = @max(1, ke.ncpus / 2);

    for (0..nreaders) |i| spawn(&reader, i);
    for (0..nwriters) |i| spawn(&writer, nreaders + i);
    spawn(&poller, nreaders + nwriters);

    var last: usize = 0;
    while (true) {
        delay_ms(1000);

        std.log.info("smr: reads: {}, writes: {}, polls: {}, read_seq: {}, write_seq: {} scans/s={}", .{
            reads.load(.monotonic),
            writes.load(.monotonic),
            polls.load(.monotonic),
            dom.clock.read_seq.load(.monotonic),
            dom.clock.write_seq.load(.monotonic),
            ke.private.smr.full_scans.load(.monotonic) - last,
        });

        last = ke.private.smr.full_scans.load(.monotonic);
    }
}
