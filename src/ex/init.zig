const std = @import("std");
const b = @import("base");
const pl = b.pl;
const ke = b.ke;

pub fn init(boot_info: *pl.BootInfo) void {
    _ = boot_info;

    pl.late_init();
    ke.sched.late_init();

    while (true) {
        std.atomic.spinLoopHint();
    }
}
