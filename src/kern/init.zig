const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const arch = r.arch;
const kep = ke.private;
const ex = r.ex;

var thread0: ke.Thread = undefined;

export fn kmain(boot_info: *r.BootInfo) callconv(.c) void {
    r.boot_info = boot_info;

    // Immediately initialize the context of what will eventually become
    // our idle thread. At this point we're already running on the kernel stack.
    thread0.init(.{
        .stack = boot_info.kernel_stack + boot_info.kernel_stack_size,
        .priority = .IdleThread,
        .entry = undefined,
        // Shouldn't block
        .turnstile = undefined,
    });

    thread0.continuation = null;
    thread0.pinned = true;

    init();
}

fn init() linksection(r.init) void {
    ke.ncpus = 1;
    kep.impl.early_init();
    kep.tunable.init();
    std.log.info("Welcome to the machine", .{});
    pl.early_init();
    kep.log.init();
    kep.cpu.init_cpu(0);
    kep.turnstile.init_turnstiles();

    kep.sched.percpu.local().current_thread = &thread0;
    kep.sched.percpu.local().idle_thread = &thread0;

    std.log.info("Zag for {s} ({s}), cmdline is \"{?s}\"", .{
        pl.name,
        arch.name,
        r.boot_info.cmdline,
    });

    ex.init();
    kep.sched.idle(null);
}
