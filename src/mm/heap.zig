const r = @import("root");
const ke = r.ke;
const mm = r.mm;
const mmp = mm.private;

pub fn init() void {
    mmp.kernel_space.arena.init(
        "kernel heap",
        .{
            .base = mmp.impl.kernel_heap_base,
            .size = r.tib(16),
            .quantum = mm.page_size,
            .qcache_max = 8 * mm.page_size,
        },
    ) catch @panic("failed to initialize kernel heap arena");
}

pub fn alloc(size: usize, policy: mm.WaitPolicy) mm.Error!*anyopaque {
    const addr = mmp.kernel_space.arena.alloc(size, .{}) catch {
        return mm.Error.OutOfMemory;
    };

    mmp.kernel_space.lock.acquire();
    const npages = size / mm.page_size;

    for (0..npages) |i| {
        const pte = mmp.pmap.wire_pte(
            &mmp.kernel_space,
            addr + (i * mm.page_size),
            policy,
        ) catch {
            mmp.kernel_space.lock.release();
            return mm.Error.OutOfMemory;
        };

        mmp.kernel_space.lock.release();

        const page = mmp.phys.alloc_opts(.{ .policy = policy }) orelse {
            return mm.Error.OutOfMemory;
        };

        mmp.kernel_space.lock.acquire();

        pte.* = mmp.impl.make_leaf_pte(page, .{ .read = true, .write = true }, 0);
    }

    mmp.kernel_space.lock.release();
    return @ptrFromInt(addr);
}

pub fn free(va: r.VAddr, size: usize) void {
    mmp.kernel_space.lock.acquire();
    mmp.tlb.reclaim_range(&mmp.kernel_space, va, size);
    mmp.kernel_space.lock.release();
}
