const config = @import("config");
pub const phys = @import("phys.zig");
pub const radix_pmap = @import("radix_pmap.zig");
pub const pmap = @import("pmap.zig");
pub const init = @import("init.zig");
pub const vmem = @import("vmem.zig");
pub const heap = @import("heap.zig");
pub const zone = @import("zone.zig");
pub const PMap = pmap.PMap;

const ke = @import("root").ke;

pub const Space = struct {
    pmap: PMap,
    arena: vmem.Arena,
    lock: ke.QSpinLock,
};

pub const impl = switch (config.arch) {
    .amd64 => @import("amd64/impl.zig"),
    .um => @import("um/impl.zig"),
    else => @compileError("unsupported architecture"),
};

pub var kernel_space: Space = undefined;
