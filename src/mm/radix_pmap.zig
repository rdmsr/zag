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

const b = @import("base");
const mm = b.mm;
const mi = mm.private;
const std = @import("std");

pub const Level = struct {
    shift: u6,
    leaf: bool,
};

pub fn RadixPmap(comptime Impl: type) type {
    return struct {
        const Self = @This();

        const num_levels = Impl.levels.len;
        const entries_per_table = 512;
        const index_mask = entries_per_table - 1;

        root_pa: b.PAddr,

        fn level_shift(level: usize) u6 {
            return Impl.levels[level].shift;
        }

        fn page_size(level: usize) usize {
            return @as(usize, 1) << level_shift(level);
        }

        fn index_for_level(va: usize, level: usize) usize {
            return (va >> level_shift(level)) & index_mask;
        }

        fn is_leaf_level(level: usize) bool {
            return Impl.levels[level].leaf;
        }

        fn leaf_level_enabled(level: usize) bool {
            return is_leaf_level(level) and Impl.is_leaf_level_enabled(level);
        }

        fn cursor(self: *Self, start_va: usize) Cursor {
            var tables: [num_levels][*]Impl.Pte = undefined;
            tables[num_levels - 1] = @ptrFromInt(mm.p2v(self.root_pa));
            return .{
                .pmap = self,
                .va = start_va,
                .tables = tables,
                .top_level = num_levels - 1,
            };
        }

        pub fn activate(self: *Self) void {
            Impl.activate(self.root_pa);
        }

        pub fn map_from(self: *Self, va: b.VAddr, size: usize, source: anytype) void {
            var c = self.cursor(va);
            var remain = size;

            while (remain > 0) {
                const item = source.next(c.va);
                c.map_range(item.pa, item.len, item.flags);
                remain -|= item.len;
            }
        }

        /// Ensure all intermediate page tables down to `target_level` exist for
        /// the given virtual address range, allocating them as needed. Useful for
        /// pre-populating a shared region (e.g. the kernel half of a user pmap)
        /// before any leaf mappings are installed.
        pub fn preallocate(self: *Self, va: b.VAddr, size: usize, target_level: usize) void {
            var c = self.cursor(va);
            var remain = size;

            // Step by one table at `target_level + 1` at a time so each
            // `walk_down` call sees a fresh index at that level.
            const step = page_size(target_level + 1);

            while (remain > 0) {
                c.walk_down(target_level, true) catch @panic("walk_down failed during preallocate");
                const advance_amount = @min(remain, step);
                c.advance(advance_amount);
                remain -= advance_amount;
            }
        }

        pub const Cursor = struct {
            pmap: *Self,
            va: b.VAddr,
            /// Cached pointers to each level's page table, filled as the cursor
            /// descends. Only indices in `[0, top_level]` are valid.
            tables: [num_levels][*]Impl.Pte,
            /// Index of the highest level for which `tables` currently holds a
            /// valid pointer. Descends toward 0 (the leaf) as `walk_down` runs.
            /// Reset upward in `advance` when the VA crosses a level boundary.
            top_level: usize,

            fn walk_down(self: *Cursor, target_level: usize, allocate: bool) error{PageNotMapped}!void {
                var current_level = self.top_level;

                while (current_level > target_level) {
                    const idx = index_for_level(self.va, current_level);
                    var pte = self.tables[current_level][idx];

                    if (!pte.present) {
                        if (!allocate) {
                            return error.PageNotMapped;
                        }

                        const new_table_pa = mi.phys.alloc();
                        const table_ptr: [*]Impl.Pte = @ptrFromInt(mm.p2v(new_table_pa));
                        @memset(table_ptr[0..entries_per_table], std.mem.zeroes(Impl.Pte));

                        pte = Impl.make_table_pte(new_table_pa);
                        self.tables[current_level][idx] = pte;
                    }

                    const child_va = mm.p2v(pte.address());
                    self.tables[current_level - 1] = @ptrFromInt(child_va);
                    self.top_level -= 1;
                    current_level -= 1;
                }
            }

            fn walk_down_resolve(self: *Cursor, target_level: usize) bool {
                self.walk_down(target_level, false) catch return false;
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

            pub fn map_range(self: *Cursor, pa: b.PAddr, size: usize, flags: mm.MapFlags) void {
                var remain = size;
                var current_pa = pa;

                while (remain > 0) {
                    const target_level = self.choose_target_level(current_pa, remain);

                    self.walk_down(target_level, true) catch @panic("walk_down failed during map_range");

                    const table = self.tables[target_level];
                    table[index_for_level(self.va, target_level)] =
                        Impl.make_leaf_pte(current_pa, flags, target_level);

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
}
