const config = @import("config");
pub const phys = @import("phys.zig");
pub const radix_pmap = @import("radix_pmap.zig");
pub const pmap = @import("pmap.zig");
pub const init = @import("init.zig");
pub const vmem = @import("vmem.zig");
pub const heap = @import("heap.zig");
pub const zone = @import("zone.zig");
pub const PMap = pmap.PMap;

pub const impl = if (@hasDecl(config, "CONFIG_ARCH_AMD64"))
    @import("amd64/impl.zig")
else if (@hasDecl(config, "CONFIG_ARCH_UM"))
    @import("um/impl.zig")
else
    @compileError("unsupported architecture");

pub var kernel_pmap: PMap = undefined;
