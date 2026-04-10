const amd64 = @import("arch");
const b = @import("base");
const mm = b.mm;
const mi = mm.private;

pub const hhdm_minimum_max_address = b.gib(4);

pub fn phys_to_virt(addr: b.PAddr) b.VAddr {
    return addr + 0xffff800000000000;
}

pub fn virt_to_phys(vaddr: b.VAddr) usize {
    return vaddr - 0xffff800000000000;
}

pub const hhdm_base = 0xffff800000000000;
pub const kernel_heap_base = 0xffffe00000000000;
pub const pfndb_base = 0xffffff0000000000;

pub const PagingImpl = struct {
    const Self = @This();

    pub const levels = [_]mi.radix_pmap.Level{
        .{ .shift = 12, .leaf = true }, // 4K
        .{ .shift = 21, .leaf = true }, // 2M
        .{ .shift = 30, .leaf = true }, // 1G
        .{ .shift = 39, .leaf = false }, // root
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

        pub fn address(self: Pte) b.PAddr {
            return @as(b.PAddr, self.addr) << 12;
        }
    };

    pub inline fn make_table_pte(pa: b.PAddr) Pte {
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

    pub inline fn make_leaf_pte(pa: b.PAddr, flags: mm.MapFlags, level: usize) Pte {
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

    pub inline fn activate(root_pa: b.PAddr) void {
        amd64.write_cr(3, root_pa);
    }

    pub fn is_leaf_level_enabled(level: usize) bool {
        if (!levels[level].leaf) return false;
        if (level == 2) return amd64.cpu_features.gib_pages;
        return true;
    }
};

pub const PMap = mi.radix_pmap.RadixPmap(PagingImpl);

pub fn init_kernel() void {
    const higher_half_start = phys_to_virt(0);
    const higher_half_size: usize = 256 * (1 << 39);

    mi.kernel_pmap.impl.root_pa = mi.phys.alloc();
    const table_ptr: [*]u64 = @ptrFromInt(mm.p2v(mi.kernel_pmap.impl.root_pa));
    @memset(table_ptr[0..512], 0);

    mi.kernel_pmap.impl.preallocate(higher_half_start, higher_half_size, 2);
}
