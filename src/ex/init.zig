const std = @import("std");
const b = @import("root");
const pl = b.pl;
const ke = b.ke;
const mm = b.mm;

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);

    pl.late_init(boot_info);
    ke.sched.late_init();

    while (true) {
        std.atomic.spinLoopHint();
    }
}
