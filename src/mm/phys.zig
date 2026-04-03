const b = @import("base");
const std = @import("std");
const rtl = @import("rtl");
const pl = b.pl;
const mm = b.mm;
const mi = mm.private;

var early_alloc_entry_idx: usize = 0;
var memory_map: *pl.BootInfo.MemMap = undefined;
var early_allocs: usize = 0;

pub var bootstrapped = false;

pub fn early_alloc() usize {
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

pub fn alloc_page() usize {
    if (!bootstrapped) {
        return early_alloc();
    }
    @panic("not implemented");
}

pub fn init(boot_info: *pl.BootInfo) linksection(b.init) void {
    memory_map = &boot_info.memory_map;

    var total_usable_memory: usize = 0;
    std.log.info("mm/phys: physical memory map:", .{});

    for (0..boot_info.memory_map.entry_count) |i| {
        const entry = boot_info.memory_map.entries[i];

        std.log.info("mm/phys: [{x:0>16} - {x:0>16}] {s}", .{ entry.base, entry.base + entry.size, @tagName(entry.type) });

        if (entry.type == .Free) {
            total_usable_memory += entry.size;
        }
    }

    const pfndb_size_required = @sizeOf(mm.Page) * (std.math.divCeil(usize, total_usable_memory, mm.page_size) catch unreachable);

    std.log.info("mm: using {} KiB for pfndb", .{pfndb_size_required / 1024});

    // Create the kernel pagemap from the early allocator.
    mi.impl.init_kernel();

    // Now map the PFN database.
    for (0..boot_info.memory_map.entry_count) |i| {
        const entry = boot_info.memory_map.entries[i];

        if (entry.type != .Free or entry.size < mm.page_size) {
            continue;
        }

        const npages = entry.size / mm.page_size;

        // 1. Calculate the exact virtual address range needed for this region's page structs.
        const start_pfn: usize = mm.page_to_pfn(entry.base);
        const exact_start = mi.impl.pfndb_base + (start_pfn * @sizeOf(mm.Page));
        const exact_end = exact_start + (npages * @sizeOf(mm.Page));

        // 2. Ensure the addresses are aligned on page boundaries.
        const map_start = std.mem.alignBackward(usize, exact_start, mm.page_size);
        const map_end = std.mem.alignForward(usize, exact_end, mm.page_size);

        // 3. Map the virtual pages.
        mi.kernel_pmap.map_range_allocating(map_start, map_end - map_start, .{
            .read = true,
            .write = true,
            .global = true,
        });
    }
}

pub fn init_pfndb() void {
    const pfndb: [*]mm.Page = @ptrFromInt(mi.impl.pfndb_base);

    for (0..memory_map.entry_count) |i| {
        const entry = memory_map.entries[i];

        if (entry.type != .Free or entry.size < mm.page_size) {
            continue;
        }

        const start_pfn: usize = mm.page_to_pfn(entry.base);
        const npages = entry.size / mm.page_size;

        for (0..npages) |j| {
            const pfn = start_pfn + j;
            const page = &pfndb[pfn];
            page.batch_count = 0;
        }
    }
}
