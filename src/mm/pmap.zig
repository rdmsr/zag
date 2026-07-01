//! Generic radix-tree page map implementation.
//!
//! `RadixPmap` is a comptime-parameterized page table walker that implements
//! virtual-to-physical address mapping over a multi-level radix tree (e.g.
//! x86-64's four-level PT). The caller supplies an
//! `Impl` type that describes the tree's level structure and provides
//! platform-specific PTE constructors.
//!
//! The `Impl` type passed to `RadixPmap` must provide:
//!
//!   - `levels: []const Level`: ordered from the leaf up to the root,
//!     each entry carrying the VA index shift and whether that level can
//!     hold a leaf (large-page) mapping.
//!   - `is_leaf_level_enabled(level: usize) bool`:runtime gate that
//!     controls whether large pages are used at a given level (e.g. to
//!     disable 1 GiB pages on hardware that lacks them).
//!   - `Pte`: the PTE type. Must be zero-initializable and expose a
//!     `present: bool` field and an `address() PAddr` method.
//!   - `make_table_pte(pa: PAddr) Pte`: construct a non-leaf PTE pointing
//!     to a child page table at `pa`.
//!   - `make_leaf_pte(pa: PAddr, flags: MapFlags, level: usize) Pte`:
//!     construct a leaf PTE mapping `pa` with the given flags at the
//!     chosen level.
//!   - `activate(root_pa: PAddr) void`: install the root page table into
//!     the CPU (e.g. write CR3 or satp).

const r = @import("root");
const rtl = @import("rtl");
const std = @import("std");
const mm = r.mm;
const mi = mm.private;

/// Describes a contiguous region of physical memory to be mapped at a given virtual address.
const MapItem = struct {
    pa: r.PAddr,
    len: usize,
    flags: mm.MapFlags,
};

const Allocator = enum {
    Boot,
    Normal,
};

/// A mapping source that maps a single contiguous virtual-to-physical region.
/// All calls to `next` return the same physical base address and size, so this
/// is intended to be consumed exactly once by `map_from`.
const ContiguousSource = struct {
    flags: mm.MapFlags,
    size: usize,
    base_va: usize,
    base_pa: usize,

    pub fn next(self: *const ContiguousSource, _: r.VAddr) MapItem {
        return .{
            .pa = self.base_pa,
            .len = self.size,
            .flags = self.flags,
        };
    }
};

/// A mapping source that allocates physical pages on demand. Each call to `next`
/// returns a single page, so this is intended to be consumed by `map_from` in a loop until the entire range is mapped.
const AllocatingSource = struct {
    flags: mm.MapFlags,
    allocator: Allocator,

    pub fn next(self: *const AllocatingSource, _: r.VAddr) MapItem {
        const pa = if (self.allocator == .Boot) mi.phys.early_alloc() else mi.phys.alloc();
        return .{
            .pa = pa,
            .len = mm.page_size,
            .flags = self.flags,
        };
    }
};

fn level_shift(level: usize) u6 {
    return mi.impl.levels[level].shift;
}

fn page_size(level: usize) usize {
    return @as(usize, 1) << level_shift(level);
}

fn index_for_level(va: usize, level: usize) usize {
    return (va >> level_shift(level)) & mi.impl.levels[level].mask;
}

pub const PMap = struct {
    const Self = @This();

    const num_levels = mi.impl.levels.len;
    const entries_per_table = 512;
    const index_mask = entries_per_table - 1;

    root_pa: r.PAddr,

    fn is_leaf_level(level: usize) bool {
        return mi.impl.levels[level].leaf;
    }

    fn leaf_level_enabled(level: usize) bool {
        return is_leaf_level(level) and mi.impl.is_leaf_level_enabled(level);
    }

    fn cursor(self: *Self, va: r.VAddr) Cursor {
        var c = Cursor{
            .pmap = self,
            .va = va,
            .tables = undefined,
            .top_level = num_levels - 1,
        };

        c.tables[num_levels - 1] = @ptrFromInt(mm.p2v(self.root_pa));
        return c;
    }

    pub fn activate(self: *Self) void {
        mi.impl.activate(self.root_pa);
    }

    pub fn map_from(self: *Self, va: r.VAddr, size: usize, source: anytype, comptime allocator: Allocator) void {
        var c = self.cursor(va);
        var remain = size;

        while (remain > 0) {
            const item = source.next(c.va);
            c.map_range(item.pa, item.len, item.flags, allocator);
            remain -|= item.len;
        }
    }

    /// Map a contiguous virtual address range to a contiguous physical address range.
    pub fn map_contiguous_range(self: *Self, va: r.VAddr, pa: r.PAddr, size: usize, flags: mm.MapFlags, comptime allocator: Allocator) void {
        const src = ContiguousSource{
            .flags = flags,
            .size = size,
            .base_va = va,
            .base_pa = pa,
        };

        self.map_from(va, size, src, allocator);
    }

    /// Map a virtual address range to physical addresses allocated on demand by the boot allocator.
    pub fn map_range_allocating(self: *Self, va: r.VAddr, size: usize, flags: mm.MapFlags, comptime allocator: Allocator) void {
        const src = AllocatingSource{
            .allocator = allocator,
            .flags = flags,
        };

        self.map_from(va, size, src, allocator);
    }

    pub fn query(self: *Self, va: r.VAddr) ?r.PAddr {
        var c = self.cursor(va);

        var level: usize = num_levels - 1;
        while (true) {
            const idx = index_for_level(va, level);
            const pte = c.tables[level][idx];

            if (!pte.present) return null;

            if (level == 0 or (leaf_level_enabled(level) and pte.huge_page)) {
                return pte.address() + (va & (page_size(level) - 1));
            }

            if (!c.walk_down_resolve(level - 1)) return null;
            level -= 1;
        }
    }

    /// Unmap a contiguous range of virtual pages.
    /// Only small pages are supported.
    /// Return a pfn that points to the physical pages that were unmapped.
    pub fn unmap(self: *Self, va: r.VAddr, size: usize) ?mi.PfnList {
        std.debug.assert(std.mem.isAligned(va, mm.page_size));

        var c = self.cursor(va);

        const npages: usize = size / mm.page_size;
        var list: rtl.List = undefined;
        list.init();

        for (0..npages) |_| {
            var level: usize = num_levels - 1;
            blk: while (true) {
                const idx = index_for_level(c.va, level);
                const pte = c.tables[level][idx];

                if (!pte.present) break :blk;

                if (level == 0) {
                    // Found a present entry, add it to the list.
                    const addr = pte.address();
                    const pfn = mm.page_to_pfn(addr);
                    const page = mm.pfn_to_struct_page(pfn);
                    list.insert_tail(&page.free.link);

                    c.tables[level][idx] = std.mem.zeroes(mi.impl.Pte);
                    break;
                }

                if (!c.walk_down_resolve(level - 1)) return null;
                level -= 1;
            }

            c.advance(mm.page_size);
        }

        if (list.is_empty()) return null;

        const head_free: *mm.PageFree = @fieldParentPtr("link", list.first());
        const tail_free: *mm.PageFree = @fieldParentPtr("link", list.last());
        const head: *mm.Page = @ptrCast(head_free);
        const tail: *mm.Page = @ptrCast(tail_free);

        return .{ .head = mm.struct_page_to_pfn(head), .tail = mm.struct_page_to_pfn(tail) };
    }

    pub const Cursor = struct {
        pmap: *Self,
        va: r.VAddr,
        /// Cached pointers to each level's page table, filled as the cursor
        /// descends. Only indices in `[0, top_level]` are valid.
        tables: [num_levels][*]mi.impl.Pte,
        /// Index of the highest level for which `tables` currently holds a
        /// valid pointer. Descends toward 0 (the leaf) as `walk_down` runs.
        /// Reset upward in `advance` when the VA crosses a level boundary.
        top_level: usize,

        fn walk_down(self: *Cursor, target_level: usize, allocate: bool, comptime allocator: Allocator) error{PageNotMapped}!void {
            var current_level = self.top_level;

            while (current_level > target_level) {
                const idx = index_for_level(self.va, current_level);
                var pte = mi.impl.Pte.load(&self.tables[current_level][idx]);

                if (!pte.present) {
                    if (!allocate) {
                        return error.PageNotMapped;
                    }

                    const new_table_pa = if (allocator == .Boot) mi.phys.early_alloc() else mi.phys.alloc();

                    const table_ptr: [*]mi.impl.Pte = @ptrFromInt(mm.p2v(new_table_pa));
                    @memset(table_ptr[0..entries_per_table], std.mem.zeroes(mi.impl.Pte));

                    pte = mi.impl.make_table_pte(new_table_pa);
                    self.tables[current_level][idx] = pte;
                }

                const child_va = mm.p2v(pte.address());
                self.tables[current_level - 1] = @ptrFromInt(child_va);
                self.top_level -= 1;
                current_level -= 1;
            }
        }

        pub fn walk_down_resolve(self: *Cursor, target_level: usize) bool {
            self.walk_down(target_level, false, .Normal) catch return false;
            return true;
        }

        /// Choose the largest page size that satisfies the alignment and
        /// size constraints of the current VA, PA, and remaining byte count.
        /// Tries large pages first; falls back to 4K.
        fn choose_target_level(self: *Cursor, pa: usize, remain: usize) usize {
            var level: usize = num_levels;
            while (level > 0) {
                level -= 1;
                if (!leaf_level_enabled(level)) continue;

                const pg_size = page_size(level);
                const align_mask = pg_size - 1;

                if (remain >= pg_size and
                    (self.va & align_mask) == 0 and
                    (pa & align_mask) == 0)
                {
                    return level;
                }
            }

            @panic("no leaf level can map current alignment/size");
        }

        pub fn map_range(self: *Cursor, pa: r.PAddr, size: usize, flags: mm.MapFlags, comptime allocator: Allocator) void {
            var remain = size;
            var current_pa = pa;

            while (remain > 0) {
                const target_level = self.choose_target_level(current_pa, remain);

                self.walk_down(target_level, true, allocator) catch @panic("walk_down failed during map_range");

                const table = self.tables[target_level];
                table[index_for_level(self.va, target_level)] =
                    mi.impl.make_leaf_pte(current_pa, flags, target_level);

                const step = page_size(target_level);
                current_pa += step;
                remain -= step;

                self.advance(step);
            }
        }

        /// Advance the cursor's virtual address by `offset` bytes and
        /// invalidate any cached table pointers that no longer apply.
        /// The cursor tracks the highest level whose index is still valid
        /// for the new VA, `walk_down` will re-descend from there on the
        /// next mapping operation.
        pub fn advance(self: *Cursor, offset: usize) void {
            const old_va = self.va;
            self.va +%= offset;

            var level: usize = num_levels - 1;
            while (level > 0) : (level -= 1) {
                const shift = level_shift(level);
                if ((old_va >> shift) != (self.va >> shift)) {
                    self.top_level = level;
                    return;
                }
            }
        }
    };
};

pub fn wire_pte(space: *mi.Space, va: r.VAddr, policy: mm.WaitPolicy) mm.Error!*mi.impl.Pte {
    std.debug.assert(space.lock.is_locked());

    var table: [*]mi.impl.Pte = @ptrFromInt(mm.p2v(mi.kernel_space.pmap.root_pa));
    var level = mi.impl.levels.len - 1;

    while (true) {
        const idx = index_for_level(va, level);
        var entry = table[idx];

        if (level == 0) {
            std.debug.assert(!entry.present);
            return &table[idx];
        }

        if (!entry.present) {
            // Release the lock while allocating a new page table, since that may block.
            space.lock.release();

            const new_table_pa = mi.phys.alloc_opts(.{ .policy = policy }) orelse {
                space.lock.acquire();
                return mm.Error.OutOfMemory;
            };

            // Re-acquire the lock and re-validate the entry, since another thread may have raced to allocate it.
            space.lock.acquire();

            entry = table[idx];

            if (entry.present) {
                // Another thread beat us to it, free the page we just allocated and continue.
                mi.phys.free(new_table_pa);
            } else {
                const new_table_ptr: [*]u64 = @ptrFromInt(mm.p2v(new_table_pa));
                @memset(new_table_ptr[0..512], 0);

                table[idx] = mi.impl.make_table_pte(new_table_pa);
                entry = table[idx];
            }
        }

        const child_va = mm.p2v(entry.address());
        table = @ptrFromInt(child_va);
        level -= 1;
    }
}
