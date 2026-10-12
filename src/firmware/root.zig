//! Library abstracting over firmware interactions.
const std = @import("std");

pub const fdt = @import("fdt.zig");

comptime {
    _ = std.testing.refAllDecls(@This());
}
