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

fn mutex_test(_: ?*anyopaque) void {
    while (true) {
        mtx.acquire();
        shared_counter += 1;
        mtx.release();
    }
}

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);

    pl.late_init(boot_info);
    mm.late_init();
    ke.sched.late_init();
    ps.init();

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
