const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const ps = r.ps;
const amd64 = @import("arch");
const turnstile = ke.private.turnstile;

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);
    ps.init();

    pl.late_init(boot_info);
    mm.late_init();
    ke.sched.late_init();
    ex.private.workqueue.init() catch @panic("e");

    if (boot_info.framebuffer != null) {
        const t = ps.thread.create_kernel(ke.Thread.Priority.default, ex.fireworks.start, boot_info) catch @panic("oom");
        ke.sched.enqueue(&t.kern);
    }

    while (true) {}

    while (true) {
        std.atomic.spinLoopHint();
    }
}
