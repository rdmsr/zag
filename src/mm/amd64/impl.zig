const amd64 = @import("arch");
const r = @import("root");
const mm = r.mm;
const mi = mm.private;

pub const hhdm_minimum_max_address = r.gib(4);

pub fn phys_to_virt(addr: r.PAddr) r.VAddr {
    return addr + 0xffff800000000000;
}

pub fn virt_to_phys(vaddr: r.VAddr) usize {
    return vaddr - 0xffff800000000000;
}

pub const hhdm_base = 0xffff800000000000;
pub const kernel_heap_base = 0xffffc00000000000;
pub const pfndb_base = 0xffffd00000000000;

pub const levels = [_]mi.PMapLevel{
    .{ .shift = 12, .mask = 0x1ff, .leaf = true }, // 4K
    .{ .shift = 21, .mask = 0x1ff, .leaf = true }, // 2M
    .{ .shift = 30, .mask = 0x1ff, .leaf = true }, // 1G
    .{ .shift = 39, .mask = 0x1ff, .leaf = false }, // root
};

pub const Pte = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    cache_disable: bool,
    accessed: bool,
    dirty: bool,
    huge_page: bool,
    global: bool,
    available: u3,
    addr: u40,
    ignored_2: u11,
    nx: bool,

    pub fn address(self: Pte) r.PAddr {
        return @as(r.PAddr, self.addr) << 12;
    }

    pub fn is_present(self: Pte) bool {
        return self.present;
    }

    pub fn load(table: *Pte) Pte {
        return @atomicLoad(Pte, table, .monotonic);
    }

    pub fn zero() Pte {
        return Pte{
            .present = false,
            .writable = false,
            .user = false,
            .write_through = false,
            .cache_disable = false,
            .accessed = false,
            .dirty = false,
            .huge_page = false,
            .global = false,
            .available = 0,
            .addr = 0,
            .ignored_2 = 0,
            .nx = false,
        };
    }
};

pub inline fn make_table_pte(pa: r.PAddr) Pte {
    return Pte{
        .present = true,
        .writable = true,
        .user = true,
        .write_through = false,
        .cache_disable = false,
        .accessed = false,
        .dirty = false,
        .huge_page = false,
        .global = false,
        .available = 0,
        .addr = @truncate(pa >> 12),
        .ignored_2 = 0,
        .nx = false,
    };
}

pub inline fn make_leaf_pte(pa: r.PAddr, flags: mm.MapFlags, level: usize) Pte {
    return Pte{
        .present = true,
        .writable = flags.write,
        .user = flags.user,
        .write_through = flags.write_through,
        .cache_disable = flags.cache_disable,
        .accessed = false,
        .dirty = false,
        .huge_page = (level > 0),
        .global = flags.global,
        .available = 0,
        .addr = @truncate(pa >> 12),
        .ignored_2 = 0,
        .nx = !flags.execute,
    };
}

pub inline fn activate(root_pa: r.PAddr) void {
    amd64.write_cr(3, root_pa);
}

pub fn is_leaf_level_enabled(level: usize) bool {
    if (!levels[level].leaf) return false;
    if (level == 2) return amd64.cpu_features.gib_pages;
    return true;
}

pub fn init_kernel() void {
    mi.kernel_space.pmap.root_pa = amd64.read_cr(3);
}
