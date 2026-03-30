const std = @import("std");
const config = @import("config");

const b = @import("base");
const ke = b.ke;
const pl = b.pl;

const init_mod = @import("init.zig");

pub const impl = if (@hasDecl(config, "CONFIG_ARCH_AMD64"))
    @import("amd64/impl.zig")
else if (@hasDecl(config, "CONFIG_ARCH_UM"))
    @import("um/impl.zig")
else
    @compileError("unsupported architecture");

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
