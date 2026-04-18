const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const amd64 = @import("arch");

fn callback(_: ?*anyopaque) void {
    std.log.info("Timer callback called", .{});
}

pub fn init(boot_info: *pl.BootInfo) void {
    mm.init(boot_info);

    pl.late_init(boot_info);
    ke.sched.late_init();

    var timer: ke.Timer = undefined;
    var dpc: ke.Dpc = .init(callback);

    timer.init();

    ke.timer.set(&timer, std.time.ns_per_ms * 50, &dpc);

    while (true) {
        std.atomic.spinLoopHint();
    }
}
