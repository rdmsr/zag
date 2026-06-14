const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const amd64 = @import("arch");
const turnstile = ke.private.turnstile;

var thread0: ke.Thread = undefined;

var mtx: ke.private.mutex.Mutex = .init();
var shared_counter: usize = 0;

fn mutex_test(_: ?*anyopaque) void {
    while (true) {
        mtx.acquire();
        shared_counter += 1;
        mtx.release();
    }
}

fn make_thread(entry: *const fn (?*anyopaque) void, arg: ?*anyopaque) *ke.Thread {
    var ret: *ke.Thread = mm.zone.gpa.create(ke.Thread) catch @panic("oom");
    const stack = mm.heap.alloc(r.kib(64)) catch @panic("wtf");

    std.log.info("Stack = {*}", .{stack});

    ret.init(@intFromPtr(stack), r.kib(64), entry, arg);

    ret.priority = ke.Thread.Priority.default;
    ret.base_priority = ret.priority;
    ret.turnstile = mm.zone.gpa.create(ke.private.turnstile.Turnstile) catch @panic("oom");
    ret.turnstile.* = .{
        .link = undefined,
        .next_free = null,
        .obj = undefined,
        .owner = null,
        .boost_link = undefined,
        .donated = null,
        .queues = undefined,
        .waiters = 0,
    };

    ret.turnstile.queues[0].init();
    ret.turnstile.queues[1].init();
    ret.turnstile_waiter = null;

    return ret;
}

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);

    pl.late_init(boot_info);
    mm.late_init();
    ke.sched.late_init();
    ke.private.turnstile.init_turnstiles();

    if (false) {
        if (boot_info.framebuffer != null) {
            const sp = mm.heap.alloc(r.kib(16)) catch @panic("oom");
            thread0.init(@intFromPtr(sp), r.kib(16), ex.fireworks.start, boot_info);
            ke.sched.enqueue(&thread0);
        }

        while (true) {}
    }

    const ipl = ke.ipl.raise(.Dispatch);

    for (0..10) |_| {
        const t = make_thread(mutex_test, null);
        ke.sched.enqueue(t);
    }

    ke.ipl.lower(ipl);

    while (true) {
        std.atomic.spinLoopHint();
    }
}
