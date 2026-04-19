const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const amd64 = @import("arch");

var thread0: ke.Thread = undefined;

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);

    pl.late_init(boot_info);
    mm.late_init();
    ke.sched.late_init();

    const sp = mm.heap.alloc(r.kib(16)) catch @panic("oom");
    thread0.init(@intFromPtr(sp), r.kib(16), ex.fireworks.start, boot_info);
    ke.sched.enqueue(&thread0);

    while (true) {
        std.atomic.spinLoopHint();
    }
}
