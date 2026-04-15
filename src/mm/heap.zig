const b = @import("base");
const ke = b.ke;
const mm = b.mm;
const mi = mm.private;

var heap_lock: ke.SpinLock = .init();
var heap_arena: mm.vmem.Arena = undefined;

pub fn init() void {
    heap_arena.init("kernel heap", mi.impl.kernel_heap_base, b.tib(16), mm.page_size) catch @panic("failed to initialize kernel heap arena");
}

pub fn alloc(size: usize) mm.Error!*anyopaque {
    const ipl = heap_lock.acquire();
    defer heap_lock.release(ipl);

    const addr = try heap_arena.alloc(size, .{});

    mi.kernel_pmap.map_range_allocating(addr, size, .{
        .read = true,
        .write = true,
        .global = true,
    });

    return @ptrFromInt(addr);
}
