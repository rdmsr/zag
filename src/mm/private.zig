const config = @import("config");
pub const phys = @import("phys.zig");
pub const pmap = @import("pmap.zig");
pub const init = @import("init.zig");
pub const vmem = @import("vmem.zig");
pub const heap = @import("heap.zig");
pub const zone = @import("zone.zig");
pub const PMap = pmap.PMap;
pub const tlb = @import("tlb.zig");

const ke = @import("root").ke;

pub const Space = struct {
    pmap: PMap,
    arena: vmem.Arena,
    lock: ke.Mutex,
};

pub const PfnList = extern struct {
    head: u32,
    tail: u32,
};

pub const PMapLevel = struct {
    shift: u6,
    mask: usize,
    leaf: bool,
};

pub const impl = switch (config.arch) {
    .amd64 => @import("amd64/impl.zig"),
    else => @compileError("unsupported architecture"),
};

pub var kernel_space: Space = .{
    .pmap = undefined,
    .arena = undefined,
    .lock = .init(),
};
