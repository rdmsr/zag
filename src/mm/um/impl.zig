const r = @import("root");
const std = @import("std");
const linux = std.os.linux;

pub var kernel_heap_base: usize = 0;
pub var pfndb_base: usize = 0;
pub const hhdm_minimum_max_address: usize = 0;

var page_table: std.AutoHashMap(usize, usize) = .init(std.heap.page_allocator);

pub fn init_kernel() void {
    kernel_heap_base = linux.mmap(
        null,
        r.gib(8),
        .{ .READ = true, .WRITE = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    r.pl.impl.check_function("mmap", kernel_heap_base);

    pfndb_base = linux.mmap(
        null,
        r.gib(1),
        .{ .READ = true, .WRITE = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    r.pl.impl.check_function("mmap", pfndb_base);
}

pub fn phys_to_virt(pa: usize) usize {
    return r.pl.impl.global_state.phys_base + pa;
}

pub fn virt_to_phys(va: usize) usize {
    return va - r.pl.impl.global_state.phys_base;
}

pub const PMap = struct {
    const Self = @This();

    pub fn map_from(_: *Self, va: r.VAddr, size: usize, source: anytype) void {
        var remain = size;

        while (remain > 0) {
            const item = source.next(va);

            var posix_flags: std.c.PROT = .{};

            posix_flags.READ = item.flags.read;
            posix_flags.WRITE = item.flags.write;
            posix_flags.EXEC = item.flags.execute;

            _ = std.c.mmap(
                @ptrFromInt(va),
                size,
                posix_flags,
                .{ .FIXED = true, .TYPE = .PRIVATE },
                r.pl.impl.global_state.phys_memory_memfd,
                @bitCast(item.pa),
            );

            page_table.put(va & ~@as(usize, 0xFFF), item.pa) catch unreachable;

            remain -|= item.len;
        }
    }

    pub fn query(_: *Self, va: r.VAddr) ?r.PAddr {
        const page = va & ~@as(usize, 0xFFF);
        const pa = page_table.get(page) orelse return null;
        return pa;
    }

    pub fn activate(_: *Self) void {}
};
