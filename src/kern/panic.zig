const std = @import("std");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

/// Panics!
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    // FIXME: this is probably broken.
    std.log.err("KERNEL PANIC: " ++ fmt, args);

    while (true) {}
}
