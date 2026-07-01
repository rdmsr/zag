const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const mi = mm.private;

pub fn init() void {
    mi.kernel_space.arena.init("kernel heap", mi.impl.kernel_heap_base, r.tib(16), mm.page_size) catch @panic("failed to initialize kernel heap arena");
}

pub fn alloc(size: usize, policy: mm.WaitPolicy) mm.Error!*anyopaque {
    mi.kernel_space.lock.acquire();

    const addr = mi.kernel_space.arena.alloc(size, .{}) catch {
        mi.kernel_space.lock.release();
        return mm.Error.OutOfMemory;
    };

    const npages = size / mm.page_size;

    for (0..npages) |i| {
        const pte = mi.pmap.wire_pte(&mi.kernel_space, addr + (i * mm.page_size), policy) catch {
            mi.kernel_space.lock.release();
            return mm.Error.OutOfMemory;
        };

        mi.kernel_space.lock.release();

        const page = mi.phys.alloc_opts(.{ .policy = policy }) orelse {
            return mm.Error.OutOfMemory;
        };

        mi.kernel_space.lock.acquire();

        pte.* = mi.impl.make_leaf_pte(page, .{ .read = true, .write = true }, 0);
    }

    mi.kernel_space.lock.release();
    return @ptrFromInt(addr);
}

pub fn free(va: r.VAddr, size: usize) void {
    mi.kernel_space.lock.acquire();
    mi.tlb.reclaim_range(&mi.kernel_space, va, size);
    mi.kernel_space.lock.release();
}
