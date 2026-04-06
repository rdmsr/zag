const std = @import("std");
const b = @import("base");
const pl = b.pl;
const ke = b.ke;
const arch = b.arch;
const ki = ke.private;
const ex = b.ex;

var thread0: ke.Thread = undefined;
var stack: [8192]u8 align(16) = undefined;

pub fn init(boot_info: *pl.BootInfo) linksection(b.init) void {
    std.log.info("hello, world", .{});
    ki.impl.early_init();
    pl.early_init(boot_info);
    ki.cpu.init_cpu();

    thread0.init(@intFromPtr(&stack), 8192, ki.sched.idle, null);
    thread0.priority = 0;
    thread0.priority_class = .Idle;

    std.log.info("Zag for {s} ({s}), cmdline is \"{?s}\"", .{ pl.name, arch.name, boot_info.cmdline });

    ex.private.init(boot_info);
}
