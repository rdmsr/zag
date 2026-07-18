//! Generic page map manipulation code.
//! Part of the code is duplicated from the kernel :(

const r = @import("root");
const mem = r.mem;

pub const PMapLevel = struct {
    shift: u6,
    mask: usize,
    leaf: bool,
};

const MapItem = struct {
    pa: usize,
    len: usize,
    flags: mem.MapFlags,
};

/// A mapping source that maps a single contiguous virtual-to-physical region.
/// All calls to `next` return the same physical base address and size, so this
/// is intended to be consumed exactly once by `map_from`.
const ContiguousSource = struct {
    flags: mem.MapFlags,
    size: usize,
    base_va: usize,
    base_pa: usize,

    pub fn next(self: *const ContiguousSource, _: usize) MapItem {
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
    flags: mem.MapFlags,

    pub fn next(self: *const AllocatingSource, _: usize) MapItem {
        const pa = mem.alloc_page();
        return .{
            .pa = pa,
            .len = r.page_size,
            .flags = self.flags,
        };
    }
};

fn level_shift(level: usize) u6 {
    return r.arch.levels[level].shift;
}

fn page_size(level: usize) usize {
    return @as(usize, 1) << level_shift(level);
}

fn index_for_level(va: usize, level: usize) usize {
    return (va >> level_shift(level)) & r.arch.levels[level].mask;
}

pub const PMap = struct {
    const Self = @This();

    const num_levels = r.arch.levels.len;
    const entries_per_table = 512;
    const index_mask = entries_per_table - 1;

    root_pa: usize,

    fn is_leaf_level(level: usize) bool {
        return r.arch.levels[level].leaf;
    }

    fn leaf_level_enabled(level: usize) bool {
        return is_leaf_level(level) and r.arch.is_leaf_level_enabled(level);
    }

    fn cursor(self: *Self, va: usize) Cursor {
        var c = Cursor{
            .pmap = self,
            .va = va,
            .tables = undefined,
            .top_level = num_levels - 1,
        };

        c.tables[num_levels - 1] = @ptrFromInt(r.mem.p2v(self.root_pa));
        return c;
    }

    pub fn activate(self: *Self) void {
        r.arch.activate(self.root_pa);
    }

    pub fn map_from(self: *Self, va: usize, size: usize, source: anytype) void {
        var c = self.cursor(va);
        var remain = size;

        while (remain > 0) {
            const item = source.next(c.va);
            c.map_range(item.pa, item.len, item.flags);
            remain -|= item.len;
        }
    }

    /// Map a contiguous virtual address range to a contiguous physical address range.
    pub fn map_contiguous_range(self: *Self, va: usize, pa: usize, size: usize, flags: r.mem.MapFlags) void {
        const src = ContiguousSource{
            .flags = flags,
            .size = size,
            .base_va = va,
            .base_pa = pa,
        };

        self.map_from(va, size, src);
    }

    /// Map a single virtual page to a physical page.
    pub fn map_page(self: *Self, va: usize, pa: usize, flags: r.mem.MapFlags) void {
        self.map_contiguous_range(va, pa, r.page_size, flags);
    }

    /// Map a virtual address range to physical addresses
    pub fn map_range_allocating(self: *Self, va: usize, size: usize, flags: mem.MapFlags) void {
        const src = AllocatingSource{
            .flags = flags,
        };

        self.map_from(va, size, src);
    }

    pub const Cursor = struct {
        pmap: *Self,
        va: usize,
        /// Cached pointers to each level's page table, filled as the cursor
        /// descends. Only indices in `[0, top_level]` are valid.
        tables: [num_levels][*]r.arch.Pte,
        /// Index of the highest level for which `tables` currently holds a
        /// valid pointer. Descends toward 0 (the leaf) as `walk_down` runs.
        /// Reset upward in `advance` when the VA crosses a level boundary.
        top_level: usize,

        fn walk_down(self: *Cursor, target_level: usize, allocate: bool) error{PageNotMapped}!void {
            var current_level = self.top_level;

            while (current_level > target_level) {
                const idx = index_for_level(self.va, current_level);
                var pte = r.arch.Pte.load(&self.tables[current_level][idx]);

                if (!pte.present) {
                    if (!allocate) {
                        return error.PageNotMapped;
                    }

                    const new_table_pa = mem.alloc_page();

                    const table_ptr: [*]r.arch.Pte = @ptrFromInt(r.mem.p2v(new_table_pa));
                    @memset(table_ptr[0..entries_per_table], r.arch.Pte.zero());

                    pte = r.arch.make_table_pte(new_table_pa);
                    self.tables[current_level][idx] = pte;
                }

                const child_va = r.mem.p2v(pte.address());
                self.tables[current_level - 1] = @ptrFromInt(child_va);
                self.top_level -= 1;
                current_level -= 1;
            }
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

        pub fn map_range(self: *Cursor, pa: usize, size: usize, flags: mem.MapFlags) void {
            var remain = size;
            var current_pa = pa;

            while (remain > 0) {
                const target_level = self.choose_target_level(current_pa, remain);

                self.walk_down(target_level, true) catch @panic("walk_down failed during map_range");

                const table = self.tables[target_level];
                table[index_for_level(self.va, target_level)] =
                    r.arch.make_leaf_pte(current_pa, flags, target_level);

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
