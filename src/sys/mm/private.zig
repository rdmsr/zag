//! Private memory management code.
const config = @import("config");
pub const phys = @import("phys.zig");
pub const pmap = @import("pmap.zig");
pub const init = @import("init.zig");
pub const heap = @import("heap.zig");
pub const zone = @import("zone.zig");
pub const PMap = pmap.PMap;
pub const tlb = @import("tlb.zig");
pub const balance = @import("balance.zig");
pub const kalloc = @import("kalloc.zig");

const r = @import("root");
const ke = r.ke;
const ex = r.ex;

pub const Space = struct {
    pmap: PMap,
    arena: ex.Arena,
    lock: ke.Mutex,
};

pub const PfnList = extern struct {
    head: r.mm.Pfn,
    tail: r.mm.Pfn,
};

pub const PMapLevel = struct {
    shift: u6,
    mask: usize,
    leaf: bool,
};

pub const impl = switch (config.arch) {
    .amd64 => @import("amd64/impl.zig"),
    .riscv64 => @import("riscv64/impl.zig"),
    else => @compileError("unsupported architecture"),
};

pub var kernel_space: Space = .{
    .pmap = undefined,
    .arena = undefined,
    .lock = undefined,
};
