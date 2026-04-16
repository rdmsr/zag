const b = @import("base");
const std = @import("std");
const linux = std.os.linux;

pub var kernel_heap_base: usize = 0;
pub var pfndb_base: usize = 0;
pub const hhdm_minimum_max_address: usize = 0;

pub fn init_kernel() void {
    kernel_heap_base = linux.mmap(
        null,
        b.gib(8),
        .{ .READ = true, .WRITE = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    b.pl.impl.check_function("mmap", kernel_heap_base);

    pfndb_base = linux.mmap(
        null,
        b.gib(1),
        .{ .READ = true, .WRITE = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    b.pl.impl.check_function("mmap", pfndb_base);
}

pub fn phys_to_virt(pa: usize) usize {
    return b.pl.impl.global_state.phys_base + pa;
}

pub fn virt_to_phys(va: usize) usize {
    return va - b.pl.impl.global_state.phys_base;
}

pub const PMap = struct {
    const Self = @This();

    pub fn map_from(_: *Self, va: b.VAddr, size: usize, source: anytype) void {
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
                b.pl.impl.global_state.phys_memory_memfd,
                @bitCast(item.pa),
            );

            remain -|= item.len;
        }
    }

    pub fn activate(_: *Self) void {}
};
