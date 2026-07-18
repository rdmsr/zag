const r = @import("root");
const config = @import("config");
const pmap = @import("pmap.zig");
const std = @import("std");

var memory_map: *r.BootInfo.MemMap = &r.loader_info.memory_map;
var alloc_idx: usize = 0;
var bump_base: usize = 0;
var map_loaded: bool = false;
var last_data_idx: ?usize = null;

const MemoryLayout = struct {
    /// Kernel direct map (if applicable)
    direct_map: usize,
    /// Kernel heap
    kernel_heap: usize,
    /// PFNDB
    pfndb: usize,
    /// Loader heap data (per-CPU data, stacks, etc.)
    loader_heap: usize,
};

pub const MapFlags = packed struct {
    read: bool = true,
    write: bool = false,
    user: bool = false,
    execute: bool = false,
    global: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
};

pub var memory_layout: MemoryLayout = undefined;

pub var pagemap: pmap.PMap = undefined;

pub fn p2v(pa: usize) usize {
    if (map_loaded) {
        return memory_layout.direct_map + pa;
    }

    return r.impl.p2v(pa);
}

fn record_loader_data(addr: usize) void {
    if (last_data_idx) |i| {
        const e = &memory_map.entries[i];
        if (e.base + e.size == addr) {
            e.size += r.page_size;
            return;
        }
    }

    last_data_idx = memory_map.entry_count;
    add_entry(addr, r.page_size, .LoaderData);
}

pub fn alloc_page() usize {
    while (alloc_idx < memory_map.entry_count) {
        const entry = &memory_map.entries[alloc_idx];

        if (entry.type != .Free or entry.size < r.page_size) {
            alloc_idx += 1;
            continue;
        }

        const addr = entry.base;

        entry.base += r.page_size;
        entry.size -= r.page_size;
        memory_map.loader_memory_used += r.page_size;
        record_loader_data(addr);

        const a: [*]u64 = @ptrFromInt(p2v(addr));

        @memset(a[0..512], 0);

        return addr;
    }

    @panic("loader: Out of memory for early allocation");
}

/// Allocate data from the loader heap.
pub fn alloc(size: usize) usize {
    const va = bump_base;
    bump_base += size;

    const npages = size / r.page_size;

    for (0..npages) |i| {
        const pa = alloc_page();

        pagemap.map_contiguous_range(va + i * r.page_size, pa, r.page_size, .{
            .read = true,
            .write = true,
        });
    }

    return va;
}

pub fn add_entry(base: usize, size: usize, @"type": r.BootInfo.MemMap.Entry.Type) void {
    memory_map.entries[memory_map.entry_count] = .{
        .base = base,
        .size = size,
        .type = @"type",
    };

    memory_map.entry_count += 1;
}

extern var text_start_addr: u8;
extern var text_end_addr: u8;
extern var rodata_start_addr: u8;
extern var rodata_end_addr: u8;
extern var data_start_addr: u8;
extern var data_end_addr: u8;

fn map_self() void {
    const layout = r.impl.get_image_layout();

    const text_start = @intFromPtr(&text_start_addr);
    const text_end = @intFromPtr(&text_end_addr);
    const rodata_start = @intFromPtr(&rodata_start_addr);
    const rodata_end = @intFromPtr(&rodata_end_addr);
    const data_start = @intFromPtr(&data_start_addr);
    const data_end = @intFromPtr(&data_end_addr);

    const text_size = text_end - text_start;
    const rodata_size = rodata_end - rodata_start;
    const data_size = data_end - data_start;

    const start_phys = layout.physical_base;
    const start_virt = layout.virtual_base;
    const until_size = text_start - start_virt;

    pagemap.map_contiguous_range(start_virt, start_phys, until_size, .{
        .read = true,
        .write = true,
        .global = true,
    });

    pagemap.map_contiguous_range(
        text_start,
        layout.physical_base + (text_start - layout.virtual_base),
        text_size,
        .{
            .read = true,
            .execute = true,
            .global = true,
        },
    );

    pagemap.map_contiguous_range(
        rodata_start,
        layout.physical_base + (rodata_start - layout.virtual_base),
        rodata_size,
        .{
            .read = true,
            .global = true,
        },
    );

    pagemap.map_contiguous_range(
        data_start,
        layout.physical_base + (data_start - layout.virtual_base),
        data_size,
        .{
            .read = true,
            .write = true,
            .global = true,
        },
    );

    const max_hhdm_address = 4 * 1024 * 1024 * 1024;

    pagemap.map_contiguous_range(
        memory_layout.direct_map,
        0,
        max_hhdm_address,
        .{
            .read = true,
            .write = true,
            .global = true,
        },
    );

    // Now go through every usable entry and map to the HHDM every part that isnt covered by [0, hhdm_minimum_max_address).
    // We can't blindly map until the maximum usable physical address because on some CPUs this might cause MCEs.
    // See https://github.com/torvalds/linux/commit/66520ebc2df3fe52eb4792f8101fac573b766baf
    for (0..memory_map.entry_count) |i| {
        const entry = memory_map.entries[i];

        if ((entry.type != .Free and entry.type != .LoaderReclaimable) or entry.size < r.page_size) {
            continue;
        }

        if (entry.base + entry.size <= max_hhdm_address) {
            continue;
        }

        var entry_start = entry.base;
        var entry_size = entry.size;

        if (entry.base < max_hhdm_address) {
            const adjust = max_hhdm_address - entry.base;
            entry_start += adjust;
            entry_size -= adjust;
        }

        pagemap.map_contiguous_range(
            memory_layout.direct_map + entry_start,
            entry_start,
            entry_size,
            .{
                .read = true,
                .write = true,
                .global = true,
            },
        );
    }
}

fn map_pfndb() void {
    const size = r.BootInfo.page_struct_size;

    // Now map the PFN database.
    for (0..memory_map.entry_count) |i| {
        const entry = memory_map.entries[i];

        if ((entry.type != .Free and entry.type != .LoaderReclaimable) or entry.size < r.page_size) {
            continue;
        }

        const npages = std.math.divCeil(usize, entry.size, r.page_size) catch unreachable;

        // 1. Calculate the exact virtual address range needed for this region's page structs.
        const start_pfn: usize = entry.base / r.page_size;
        const exact_start = memory_layout.pfndb + (start_pfn * size);
        const exact_end = exact_start + (npages * size);

        // 2. Ensure the addresses are aligned on page boundaries.
        const map_start = std.mem.alignBackward(usize, exact_start, r.page_size);
        const map_end = std.mem.alignForward(usize, exact_end, r.page_size);

        // 3. Map the virtual pages.
        pagemap.map_range_allocating(
            map_start,
            map_end - map_start,
            .{
                .read = true,
                .write = true,
                .global = true,
            },
        );
    }
}

pub fn init() void {
    const vbits = r.arch.virtual_bits;

    // Figure out the memory layout.
    // NOTE: This assumes 64-bit (fix this when we port to 32-bit).
    // Higher half starts here, we give 1/2 to the kernel for its direct map.
    const higher_half_start: usize = @bitCast(-@as(isize, 1) << vbits - 1);
    const kernel_heap = higher_half_start + (@as(usize, 1) << vbits - 2);

    // Then, we give 16 TiB to the kernel heap.
    const pfndb = kernel_heap + 0x100000000000;

    // Finally, the pfndb has 1 TiB.
    const loader_heap = pfndb + 0x10000000000;

    memory_layout = .{
        .direct_map = higher_half_start,
        .kernel_heap = kernel_heap,
        .pfndb = pfndb,
        .loader_heap = loader_heap,
    };

    bump_base = loader_heap;

    pagemap.root_pa = alloc_page();

    // Pre-allocate the top 256 entries.
    const table_ptr: [*]r.arch.Pte = @ptrFromInt(p2v(pagemap.root_pa));
    @memset(table_ptr[0..512], r.arch.Pte.zero());

    for (256..512) |i| {
        table_ptr[i] = r.arch.make_table_pte(alloc_page());
    }

    map_self();
    map_pfndb();

    map_loaded = true;
    r.arch.activate(pagemap.root_pa);
}
