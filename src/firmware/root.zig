//! Library abstracting over firmware interactions.
const std = @import("std");

pub const fdt = @import("fdt.zig");
pub const fw_cfg = @import("fw_cfg.zig");

comptime {
    _ = std.testing.refAllDecls(@This());
}
