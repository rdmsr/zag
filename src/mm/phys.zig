//! Physical memory allocator:
//! - Uses a per-CPU magazined allocator with a global Treiber stack as the fallback.
//! Each CPU has 4 batches of 64 pages each for fast allocation and deallocation without contention.
//!  When a CPU's active batch is exhausted, it tries to get a new batch from its local depot.
//!  If the depot is empty, it pops a batch from the global stack.
//! When freeing pages, they are added to the active batch until it reaches capacity,
//!  at which point the full batch is moved to the local depot.
//!  If the depot is full when trying to add a new batch, one batch is pushed back to the global stack to make room.
const b = @import("base");
const std = @import("std");
const rtl = @import("rtl");
const pl = b.pl;
const mm = b.mm;
const mi = mm.private;
const ke = b.ke;

// === Early state ===
var bootstrapped = false;
var early_alloc_entry_idx: usize = 0;
var memory_map: *pl.BootInfo.MemMap = undefined;
var early_allocs: usize = 0;

// === Memory allocator state ===
/// Head for the global treiber stack.
const GlobalHead = packed struct(u64) {
    pfn: mm.Pfn,
    // A 32-bit ABA tag is more than enough for this,
    // on 32-bit machines which do not support cmpxchg8b, we could use 12 bits instead.
    tag: u32,
};

/// Per-CPU state.
const PerCpu = struct {
    depot: [4]*mm.Page,
    depot_count: u8,
    active_batch: ?*mm.Page,
    active_count: u8,
};

const percpu = ke.CpuLocal(PerCpu, undefined);

const null_pfn: mm.Pfn = std.math.maxInt(mm.Pfn);

// TODO: make this configurable (or dynamic).
const batch_size: u8 = 64;

var batch_pool: std.atomic.Value(GlobalHead) = .init(.{
    .pfn = null_pfn,
    .tag = 0,
});

/// Push a batch of free pages to the global pool.
fn push_to_pool(batch: *mm.Page) void {
    var old_head = batch_pool.load(.acquire);

    while (true) {
        batch.batch_next = old_head.pfn;

        const new_head = GlobalHead{
            .pfn = mm.struct_page_to_pfn(batch),
            .tag = old_head.tag +% 1,
        };

        old_head = batch_pool.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) orelse break;
    }
}

/// Pop a batch of free pages from the global pool. Returns null if the pool is empty.
fn pop_from_pool() ?*mm.Page {
    var old_head = batch_pool.load(.acquire);

    while (true) {
        const batch_pfn = old_head.pfn;

        if (batch_pfn == null_pfn) {
            return null;
        }

        const batch = mm.pfn_to_struct_page(batch_pfn);

        const new_head = GlobalHead{
            .pfn = batch.batch_next,
            .tag = old_head.tag + 1,
        };

        old_head = batch_pool.cmpxchgWeak(old_head, new_head, .acq_rel, .acquire) orelse return batch;
    }

    return null;
}

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
pub fn alloc() b.PAddr {
    if (!bootstrapped) {
        return early_alloc();
    }

    const ipl = ke.ipl.raise(.High);
    const cpu = percpu.local();

    defer ke.ipl.lower(ipl);

    if (cpu.active_count == 0) {
        // Our batch is empty, get another one.
        if (cpu.depot_count > 0) {
            // Get a new batch from the local depot.
            cpu.depot_count -= 1;
            cpu.active_batch = cpu.depot[cpu.depot_count];
            cpu.active_count = batch_size;
        } else {
            // Get one from the global pool.
            const new_batch = pop_from_pool();

            if (new_batch) |new| {
                cpu.active_batch = new;
                cpu.active_count = new.batch_count;
            } else {
                // TODO: call an IPI here for the other CPUs to fill the global pool before giving up.
                @panic("OOM");
            }
        }
    }

    const batch = cpu.active_batch.?;

    if (cpu.active_count > 1) {
        // Pop the next page from the batch and set it as the new head.
        const next_page = mm.pfn_to_struct_page(batch.next_pfn);
        cpu.active_batch = next_page;
    } else {
        cpu.active_batch = null;
    }

    cpu.active_count -= 1;

    return mm.pfn_to_page(mm.struct_page_to_pfn(batch));
}

/// Free a page of physical memory.
pub fn free(addr: b.PAddr) void {
    const ipl = ke.ipl.raise(.High);
    defer ke.ipl.lower(ipl);

    const cpu = percpu.local();

    const page = mm.pfn_to_struct_page(mm.page_to_pfn(addr));

    if (cpu.active_batch) |curr| {
        // Add the page to the current batch.
        page.next_pfn = mm.struct_page_to_pfn(curr);
    } else {
        page.next_pfn = null_pfn;
    }

    cpu.active_batch = page;
    cpu.active_count += 1;

    if (cpu.active_count == batch_size) {
        // The batch is full, move it to the depot.
        page.batch_count = @intCast(cpu.active_count);

        if (cpu.depot_count == cpu.depot.len) {
            // The depot is full, push one batch back to the global pool to make room.
            push_to_pool(cpu.depot[0]);

            cpu.depot[0] = cpu.depot[1];
            cpu.depot[1] = cpu.depot[2];
            cpu.depot[2] = cpu.depot[3];
            cpu.depot_count -= 1;
        }

        cpu.depot[cpu.depot_count] = cpu.active_batch.?;
        cpu.depot_count += 1;

        cpu.active_batch = null;
        cpu.active_count = 0;
    }
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
