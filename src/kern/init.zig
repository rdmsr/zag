const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const arch = r.arch;
const ki = ke.private;
const ex = r.ex;

var thread0: ke.Thread = undefined;

export fn kmain(boot_info: *r.BootInfo) callconv(.c) void {
    r.boot_info = boot_info;

    thread0.init(
        boot_info.kernel_stack,
        boot_info.kernel_stack_size,
        ke.Thread.Priority.idle_low,
        init,
        null,
    );
    thread0.pinned = true;

    // Jump into the thread.
    thread0.context.load();
}

pub fn init(_: ?*anyopaque) linksection(r.init) void {
    ke.ncpus = 1;
    ki.impl.early_init();
    ki.tunable.init();
    std.log.info("Welcome to the machine", .{});
    pl.early_init();
    ki.log.init();
    ki.cpu.init_cpu(0);
    ki.turnstile.init_turnstiles();

    ki.sched.percpu.local().current_thread = &thread0;
    ki.sched.percpu.local().idle_thread = &thread0;

    std.log.info("Zag for {s} ({s}), cmdline is \"{?s}\"", .{ pl.name, arch.name, r.boot_info.cmdline });

    ex.init();
    ki.sched.idle(null);
}
