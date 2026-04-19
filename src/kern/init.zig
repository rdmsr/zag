const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const arch = r.arch;
const ki = ke.private;
const ex = r.ex;

var thread0: ke.Thread = undefined;
var stack: [r.kib(16)]u8 align(16) = undefined;

pub fn init(boot_info: *pl.BootInfo) linksection(r.init) void {
    ki.impl.early_init();
    std.log.info("hello, world", .{});
    pl.early_init(boot_info);
    ki.cpu.init_cpu(0);

    thread0.init(@intFromPtr(&stack), r.kib(16), ki.sched.idle, null);
    thread0.priority = 0;
    thread0.priority_class = .Idle;

    ki.sched.percpu.local().current_thread = &thread0;

    std.log.info("Zag for {s} ({s}), cmdline is \"{?s}\"", .{ pl.name, arch.name, boot_info.cmdline });

    ex.private.init(boot_info);
}
