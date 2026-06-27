const r = @import("root");
const std = @import("std");
const rtl = @import("rtl");
const pl = r.pl;
const mm = r.mm;
const mi = mm.private;
const ke = r.ke;

const log = std.log.scoped(.@"mm/phys");

var bootstrapped = false;
var early_alloc_entry_idx: usize = 0;
var memory_map: *pl.BootInfo.MemMap = undefined;
var early_allocs: usize = 0;
var list_lock: ke.SpinLock = undefined;
var free_list: rtl.List = undefined;

pub var usable_memory: std.atomic.Value(usize) = .init(0);

fn early_alloc() usize {
    while (early_alloc_entry_idx < memory_map.entry_count) {
        const entry = &memory_map.entries[early_alloc_entry_idx];

        if (entry.type != .Free or entry.size < mm.page_size) {
            early_alloc_entry_idx += 1;
            continue;
        }

        const addr = entry.base;

        entry.base += mm.page_size;
        entry.size -= mm.page_size;
        early_allocs += mm.page_size;

        return addr;
    }

    @panic("mm/phys: Out of memory for early allocation");
}

/// Allocate a page of physical memory.
pub fn alloc() r.PAddr {
    if (!bootstrapped) {
        @branchHint(.unlikely);
        return early_alloc();
    }

    const ipl = list_lock.acquire();

    if (free_list.is_empty()) {
        list_lock.release(ipl);
        // FIXME: wait for free memory
        @panic("mm/phys: Out of memory for physical allocation");
    }

    const head = free_list.first();
    head.remove();

    _ = usable_memory.fetchSub(mm.page_size, .monotonic);

    const elem: *mm.PageFree = @fieldParentPtr("link", head);
    const page: *mm.Page = @ptrCast(elem);
    const phys_addr = mm.pfn_to_page(mm.struct_page_to_pfn(page));

    list_lock.release(ipl);

    return phys_addr;
}

/// Free a page of physical memory.
pub fn free(addr: r.PAddr) void {
    const page: *mm.Page = mm.pfn_to_struct_page(mm.page_to_pfn(addr));

    const ipl = list_lock.acquire();
    _ = usable_memory.fetchAdd(mm.page_size, .monotonic);
    free_list.insert_head(&page.free.link);
    list_lock.release(ipl);
}

/// Free a list of pages of physical memory.
pub fn free_batch(head: *mm.Page, tail: *mm.Page, count: usize) void {
    const ipl = list_lock.acquire();

    tail.free.link.next = free_list.first();
    free_list.insert_head(&head.free.link);

    _ = usable_memory.fetchAdd(count * mm.page_size, .monotonic);

    list_lock.release(ipl);
}

pub fn init(boot_info: *pl.BootInfo) linksection(r.init) void {
    memory_map = &boot_info.memory_map;
    free_list.init();

    var total_usable_memory: usize = 0;
    log.info("physical memory map:", .{});

    for (0..boot_info.memory_map.entry_count) |i| {
        const entry = boot_info.memory_map.entries[i];

        log.info("[{x:0>16}-{x:0>16}] {s}", .{ entry.base, entry.base + entry.size, @tagName(entry.type) });

        if (entry.type == .Free) {
            total_usable_memory += entry.size;
        }
    }

    const pfndb_size_required = @sizeOf(mm.Page) * (std.math.divCeil(usize, total_usable_memory, mm.page_size) catch unreachable);

    log.info("using {} KiB for pfndb ({} bytes per page)", .{ pfndb_size_required / 1024, @sizeOf(mm.Page) });

    // Create the kernel pagemap from the early allocator.
    mi.impl.init_kernel();

    // Now map the PFN database.
    for (0..boot_info.memory_map.entry_count) |i| {
        const entry = boot_info.memory_map.entries[i];

        if (entry.type != .Free or entry.size < mm.page_size) {
            continue;
        }

        const npages = std.math.divCeil(usize, entry.size, mm.page_size) catch unreachable;

        // 1. Calculate the exact virtual address range needed for this region's page structs.
        const start_pfn: usize = mm.page_to_pfn(entry.base);
        const exact_start = mi.impl.pfndb_base + (start_pfn * @sizeOf(mm.Page));
        const exact_end = exact_start + (npages * @sizeOf(mm.Page));

        // 2. Ensure the addresses are aligned on page boundaries.
        const map_start = std.mem.alignBackward(usize, exact_start, mm.page_size);
        const map_end = std.mem.alignForward(usize, exact_end, mm.page_size);

        // 3. Map the virtual pages.
        mi.kernel_space.pmap.map_range_allocating(map_start, map_end - map_start, .{
            .read = true,
            .write = true,
            .global = true,
        });
    }
}

pub fn init_pfndb() void {
    for (0..memory_map.entry_count) |i| {
        const entry = memory_map.entries[i];

        if (entry.type != .Free or entry.size < mm.page_size) {
            continue;
        }

        const npages = entry.size / mm.page_size;

        for (0..npages) |j| {
            free(entry.base + (j * mm.page_size));
        }
    }

    bootstrapped = true;
}
