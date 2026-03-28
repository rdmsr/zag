const std = @import("std");
const b = @import("base");
const pl = b.pl;
const ke = b.ke;
const ki = ke.private;

var thread0: ke.Thread = undefined;

var stack: [8192]u8 align(16) = undefined;

fn handler(_: ?*anyopaque) void {
    std.log.info("Hi! CPU {}", .{ke.curcpu().id});

    while (true) {}
}

var temp_stack1: [8192]u8 align(16) = undefined;
var temp_stack2: [8192]u8 align(16) = undefined;
var temp_stack3: [8192]u8 align(16) = undefined;

var stacks: []const []u8 = &.{&temp_stack1, &temp_stack2, &temp_stack3};
var which_stack: usize = 0;

fn make_thread(entry: *const fn (?*anyopaque) void, td: *ke.Thread, arg: ?*anyopaque) void {
    std.debug.assert(which_stack < 3);
    const _stack = stacks[which_stack];
    which_stack += 1;

    td.init(@intFromPtr(_stack.ptr), 16384, entry, arg);
}

var threads: [1]ke.Thread = undefined;

pub fn init(boot_info: *pl.BootInfo) linksection(b.init) void {
    pl.early_init();
    ki.bootstrap_cpu.init(&thread0);

    thread0.init(@intFromPtr(&stack), 8192, ki.sched.idle, null);
    thread0.priority = 0;
    thread0.priority_class = .Idle;

    std.log.info("hello, world", .{});
    std.log.info("Zag for {s}, cmdline is {?s}", .{ pl.name, boot_info.cmdline });

    pl.late_init();

    ki.sched.late_init();

    if (boot_info.framebuffer == null) {
        const ipl = ke.ipl.raise(.Dispatch);

        for (&threads) |*td| {
            make_thread(&handler, td, null);
            td.priority = ke.Thread.Priority.default;
            td.priority_class = .Batch;
            ke.sched.enqueue(td);
        }

        ke.ipl.lower(ipl);
    } else {
        // make_thread(&b.ex.fireworks.start, &threads[0], boot_info);
        // ke.sched.enqueue(&threads[0]);
    }

    while (true) {}
}
