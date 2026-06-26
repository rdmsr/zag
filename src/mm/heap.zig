const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const mi = mm.private;

pub fn init() void {
    mi.kernel_space.arena.init("kernel heap", mi.impl.kernel_heap_base, r.tib(16), mm.page_size) catch @panic("failed to initialize kernel heap arena");
}

pub fn alloc(size: usize) mm.Error!*anyopaque {
    const ipl = mi.kernel_space.lock.acquire();
    defer mi.kernel_space.lock.release(ipl);

    const addr = try mi.kernel_space.arena.alloc(size, .{});

    mi.kernel_space.pmap.map_range_allocating(addr, size, .{
        .read = true,
        .write = true,
        .global = false,
    });

    return @ptrFromInt(addr);
}

pub fn free(va: r.VAddr, size: usize) void {
    const ipl = mi.kernel_space.lock.acquire();
    mi.tlb.reclaim_range(&mi.kernel_space, va, size);
    mi.kernel_space.lock.release(ipl);
}
