const rv64 = @import("arch");
const r = @import("root");
const mm = r.mm;
const mmp = mm.private;

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

pub const levels = [_]mmp.PMapLevel{
    .{ .shift = 12, .mask = 0x1ff, .leaf = true }, // 4K
    .{ .shift = 21, .mask = 0x1ff, .leaf = true }, // 2M
    .{ .shift = 30, .mask = 0x1ff, .leaf = true }, // 1G
    .{ .shift = 39, .mask = 0x1ff, .leaf = false }, // root
};

pub const Pte = packed struct(u64) {
    present: bool,
    read: bool,
    write: bool,
    exec: bool,
    user: bool,
    global: bool,
    access: bool,
    dirty: bool,
    rsw: u2,
    addr: u44,
    reserved: u7,
    pbmt: u2,
    n: bool,

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
            .read = false,
            .write = false,
            .exec = false,
            .user = false,
            .global = false,
            .access = false,
            .dirty = false,
            .rsw = 0,
            .addr = 0,
            .reserved = 0,
            .pbmt = 0,
            .n = false,
        };
    }
};

pub inline fn make_table_pte(pa: r.PAddr) Pte {
    return Pte{
        .present = true,
        .read = false,
        .write = false,
        .exec = false,
        .user = false,
        .global = false,
        .access = false,
        .dirty = false,
        .rsw = 0,
        .addr = @truncate(pa >> 12),
        .reserved = 0,
        .pbmt = 0,
        .n = false,
    };
}

pub inline fn make_leaf_pte(pa: r.PAddr, flags: mm.MapFlags, level: usize) Pte {
    _ = level;
    return Pte{
        .present = true,
        .read = flags.read or flags.write,
        .write = flags.write,
        .exec = flags.execute,
        .user = flags.user,
        .global = flags.global,
        .access = true,
        .dirty = flags.write,
        .rsw = 0,
        .addr = @truncate(pa >> 12),
        .reserved = 0,
        .pbmt = 0,
        .n = false,
    };
}

pub inline fn activate(root_pa: r.PAddr) void {
    rv64.write_csr("satp", (@as(u64, 9) << 60) | (root_pa >> 12));
    rv64.sfence_vma();
}

pub fn is_leaf_level_enabled(level: usize) bool {
    if (!levels[level].leaf) return false;
    return true;
}

pub fn init_kernel() void {
    mmp.kernel_space.pmap.root_pa = (rv64.read_csr("satp") & ((@as(u64, 1) << 44) - 1)) << 12;
}
