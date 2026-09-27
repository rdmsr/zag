const riscv64 = @import("arch");
const r = @import("root");
const pmap = @import("../pmap.zig");

pub const levels = [_]pmap.PMapLevel{
    .{ .shift = 12, .mask = 0x1ff, .leaf = true }, // 4K
    .{ .shift = 21, .mask = 0x1ff, .leaf = true }, // 2M
    .{ .shift = 30, .mask = 0x1ff, .leaf = true }, // 1G
    .{ .shift = 39, .mask = 0x1ff, .leaf = false }, // root
};

pub const virtual_bits: usize = 48;

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

    pub fn address(self: Pte) usize {
        return @as(usize, self.addr) << 12;
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

pub inline fn make_table_pte(pa: usize) Pte {
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

pub inline fn make_leaf_pte(pa: usize, flags: r.mem.MapFlags, level: usize) Pte {
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

pub inline fn activate(root_pa: usize) void {
    riscv64.write_csr("satp", (@as(u64, 9) << 60) | (root_pa >> 12));
    riscv64.sfence_vma();
}

pub inline fn flush(va: usize) void {
    riscv64.sfence_vma_page(va);
}

pub fn is_leaf_level_enabled(level: usize) bool {
    if (!levels[level].leaf) return false;
    return true;
}

pub fn debug_write(c: u8) void {
    // OpenSBI debug ext
    asm volatile ("ecall"
        :
        : [char] "{a0}" (@as(usize, c)),
          [extension] "{a7}" (@as(usize, 1)),
        : .{ .memory = true });
}

pub fn init() void {
    r.loader_info.arch_info = .{};
}
