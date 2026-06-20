const std = @import("std");
const config = @import("config");

const init_mod = @import("init.zig");

pub const impl = switch (config.arch) {
    .amd64 => @import("amd64/impl.zig"),
    .um => @import("um/impl.zig"),
    else => @compileError("unsupported architecture"),
};

pub const init = init_mod.init;

// === Exported Modules ===
pub const ipl = @import("ipl.zig");
pub const panic = @import("panic.zig");
pub const spinlock = @import("spinlock.zig");
pub const log = @import("log.zig");
pub const cpu = @import("cpu.zig");
pub const thread = @import("thread.zig");
pub const dpc = @import("dpc.zig");
pub const time = @import("time.zig");
pub const sched = @import("sched.zig");
pub const wait = @import("wait.zig");
pub const timer = @import("timer.zig");
pub const log_ring = @import("log_ring.zig");
pub const event = @import("event.zig");
pub const turnstile = @import("turnstile.zig");
pub const mutex = @import("mutex.zig");
pub const queue = @import("queue.zig");
