const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const mi = mm.private;

pub fn init() void {
    mi.kernel_space.arena.init("kernel heap", mi.impl.kernel_heap_base, r.tib(16), mm.page_size) catch @panic("failed to initialize kernel heap arena");
}

pub fn alloc(size: usize, policy: mm.WaitPolicy) mm.Error!*anyopaque {
    _ = policy;

    mi.kernel_space.lock.acquire();

    const addr = try mi.kernel_space.arena.alloc(size, .{});

    mi.kernel_space.pmap.map_range_allocating(addr, size, .{ .read = true, .write = true }, .DontWaitForMemory);

    mi.kernel_space.lock.release();

    return @ptrFromInt(addr);
}

pub fn free(va: r.VAddr, size: usize) void {
    mi.kernel_space.lock.acquire();
    mi.tlb.reclaim_range(&mi.kernel_space, va, size);
    mi.kernel_space.lock.release();
}
