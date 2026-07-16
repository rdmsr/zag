const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const ps = r.ps;
const exp = ex.private;
const rtl = @import("rtl");

// XXX
const fbconsole = @import("../dev/fbconsole.zig");

pub fn init(boot_info: *r.BootInfo) void {
    mm.init(boot_info);
    ps.init();

    pl.late_init(boot_info);
    mm.late_init();
    ke.sched.late_init();
    exp.workqueue.init() catch @panic("e");
    exp.console.init();

    if (boot_info.framebuffer != null) {
        //   fbconsole.init(boot_info);

        const t = ps.thread.create_kernel(ke.Thread.Priority.default, ex.fireworks.start, boot_info) catch @panic("oom");
        ke.sched.enqueue(&t.kern);
    }

    while (true) {
        std.atomic.spinLoopHint();
    }
}
