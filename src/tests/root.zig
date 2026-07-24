//! kernel-mode stress tests
const std = @import("std");
const fireworks = @import("fireworks.zig");
const smr = @import("smr.zig");
const smr_pi = @import("smr_pi.zig");
const turnstile = @import("turnstile.zig");
const mutex = @import("mutex.zig");

pub const tests: std.StaticStringMap(*const fn (?*anyopaque) void) = .initComptime(.{
    .{ "fireworks", fireworks.start },
    .{ "smr", smr.start },
    .{ "smr_pi", smr_pi.start },
    .{ "turnstile", turnstile.start },
    .{ "mutex", mutex.start },
});
