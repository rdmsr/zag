//! kernel-mode stress tests
const std = @import("std");
const fireworks = @import("fireworks.zig");

const TestFn = *const fn (?*anyopaque) void;

pub const tests = std.StaticStringMap(TestFn).initComptime(.{
    .{ "fireworks", fireworks.start },
});
