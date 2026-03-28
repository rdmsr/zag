const std = @import("std");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

pub fn panic(
    msg: []const u8,
    first_trace_addr: ?usize,
) noreturn {
    _ = first_trace_addr;

    std.log.err("KERNEL PANIC: {s}", .{msg});

    while (true) {}
}
