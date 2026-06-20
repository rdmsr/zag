const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const ps = r.ps;
const amd64 = @import("arch");
const turnstile = ke.private.turnstile;

var mtx: ke.private.mutex.Mutex = .init();
var shared_counter: usize = 0;

var work_item: ex.WorkItem = undefined;
var work_item2: ex.WorkItem = undefined;

fn mutex_test(_: ?*anyopaque) void {
    while (true) {
        mtx.acquire();
        shared_counter += 1;
        mtx.release();
    }
}

fn foo(_: ?*anyopaque) void {
    std.log.info("foo cpu {}", .{ke.cpu.current()});
    var timer: ke.Timer = undefined;
    timer.init();
    ke.timer.set(&timer, std.time.ns_per_ms * 500, null);
    _ = ke.wait.wait_one(&timer.hdr, null) catch unreachable;
}

fn bar(_: ?*anyopaque) void {
    std.log.info("bar cpu {}", .{ke.cpu.current()});
}

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);

    pl.late_init(boot_info);
    mm.late_init();
    ke.sched.late_init();
    ps.init();
    ex.private.workqueue.init() catch @panic("e");

    work_item = .init(.Normal, foo, null);
    work_item2 = .init(.Normal, bar, null);

    ex.workqueue.enqueue(&work_item);
    ex.workqueue.enqueue(&work_item2);

    if (false) {
        if (boot_info.framebuffer != null) {
            const t = ps.thread.create_kernel(ke.Thread.Priority.default, ex.fireworks.start, boot_info) catch @panic("oom");
            ke.sched.enqueue(&t.kern);
        }

        while (true) {}
    }

    const ipl = ke.ipl.raise(.Dispatch);

    for (0..10) |_| {
        const t = ps.thread.create_kernel(ke.Thread.Priority.default, mutex_test, null) catch @panic("oom");
        ke.sched.enqueue(&t.kern);
    }

    ke.ipl.lower(ipl);

    while (true) {
        std.atomic.spinLoopHint();
    }
}
