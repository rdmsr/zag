const r = @import("root");
const std = @import("std");
const rtl = @import("rtl");
const pl = r.pl;
const mm = r.mm;
const mi = mm.private;
const ke = r.ke;

const log = std.log.scoped(.@"mm/phys");

const free_pages_limit = 128;

var bootstrapped = false;
var early_alloc_entry_idx: usize = 0;
var memory_map: *pl.BootInfo.MemMap = undefined;
var early_allocs: usize = 0;
var list_lock: ke.SpinLock = .init();
var free_list: rtl.List = undefined;

var free_page_event: ke.Event = undefined;

var free_pages: usize = 0;

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

// Wait for pages to be available.
// List lock is held.
fn wait_for_pages(old_ipl: ke.Ipl) void {
    var ipl = old_ipl;

    std.debug.assert(@intFromEnum(ipl) < @intFromEnum(ke.Ipl.Dispatch));

    if (free_pages >= free_pages_limit) {
        return;
    }

    var cnt = free_pages;

    while (cnt < free_pages_limit) {
        free_page_event.reset();

        list_lock.release(ipl);

        _ = ke.wait.wait_one(&free_page_event.hdr, null) catch unreachable;

        ipl = list_lock.acquire();
        cnt = free_pages;
    }
}

/// Allocate a page of physical memory.
/// This may block if no memory is available.
pub fn alloc() r.PAddr {
    if (!bootstrapped) {
        @branchHint(.unlikely);
        return early_alloc();
    }
    const ipl = list_lock.acquire();
    defer list_lock.release(ipl);

    wait_for_pages(ipl);

    std.debug.assert(!free_list.is_empty());

    const head = free_list.first();
    head.remove();

    _ = usable_memory.fetchSub(mm.page_size, .monotonic);
    free_pages -= 1;

    const elem: *mm.PageFree = @fieldParentPtr("link", head);
    const page: *mm.Page = @ptrCast(elem);
    const phys_addr = mm.pfn_to_page(mm.struct_page_to_pfn(page));

    return phys_addr;
}

pub fn alloc_opts(opts: struct { policy: mm.WaitPolicy }) ?r.PAddr {
    if (!bootstrapped) {
        @branchHint(.unlikely);
        return early_alloc();
    }

    const ipl = list_lock.acquire();
    defer list_lock.release(ipl);

    if (free_list.is_empty() and opts.policy == .DontWaitForMemory) {
        return null;
    } else if (opts.policy == .WaitForMemory) {
        wait_for_pages(ipl);
    }

    std.debug.assert(free_pages > 0);
    std.debug.assert(!free_list.is_empty());

    const head = free_list.first();
    head.remove();

    _ = usable_memory.fetchSub(mm.page_size, .monotonic);
    free_pages -= 1;

    const elem: *mm.PageFree = @fieldParentPtr("link", head);
    const page: *mm.Page = @ptrCast(elem);
    const phys_addr = mm.pfn_to_page(mm.struct_page_to_pfn(page));

    return phys_addr;
}

/// Free a page of physical memory.
pub fn free(addr: r.PAddr) void {
    const page: *mm.Page = mm.pfn_to_struct_page(mm.page_to_pfn(addr));

    const ipl = list_lock.acquire();
    _ = usable_memory.fetchAdd(mm.page_size, .monotonic);
    free_list.insert_head(&page.free.link);
    free_pages += 1;
    if (free_pages >= free_pages_limit) {
        free_page_event.signal();
    }
    list_lock.release(ipl);
}

/// Free a list of pages of physical memory.
pub fn free_batch(head: *mm.Page, tail: *mm.Page, count: usize) void {
    const ipl = list_lock.acquire();

    const first = free_list.first();

    head.free.link.prev = &free_list.head;
    tail.free.link.next = first;
    first.prev = &tail.free.link;
    free_list.head.next = &head.free.link;

    _ = usable_memory.fetchAdd(count * mm.page_size, .monotonic);

    free_pages += count;

    if (free_pages >= free_pages_limit) {
        free_page_event.signal();
    }

    list_lock.release(ipl);
}

pub fn init(boot_info: *pl.BootInfo) linksection(r.init) void {
    memory_map = &boot_info.memory_map;
    free_list.init();
    free_page_event.init(.Notification);

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
        mi.kernel_space.pmap.map_range_allocating(
            map_start,
            map_end - map_start,
            .{
                .read = true,
                .write = true,
                .global = true,
            },
            .DontWaitForMemory,
        );
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
            const page: *mm.Page = mm.pfn_to_struct_page(mm.page_to_pfn(entry.base + (j * mm.page_size)));

            free_list.insert_head(&page.free.link);
            free_pages += 1;

            _ = usable_memory.fetchAdd(mm.page_size, .monotonic);
        }
    }

    bootstrapped = true;
}
