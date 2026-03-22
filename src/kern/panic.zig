const std = @import("std");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

/// Panics!
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    ki.log.debug_lock.acquire_no_ipl();

    var buf: [1024]u8 = undefined;

    const str = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;

    ki.log.print("Panic!\n");
    ki.log.print(str);

    ki.log.debug_lock.release_no_ipl();
    while (true) {}
}
