//! Generic resource allocator, based on the vmem allocator described in:
//! Jeff Bonwick and Jonathan Adams'
//! "Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources"
//!
//! ## Overview
//!
//! A vmem arena manages a contiguous range of an arbitrary resource (virtual address
//! space, PIDs, etc.) by tracking free and allocated regions as a list of segments.
//! Each segment has a base address and a size.
//!
//! ## Data structures
//!
//! An arena is composed of three data structures:
//!
//! 1. Segment list: an address-ordered doubly-linked list of all segments, both
//!    free and allocated. Used for coalescing on free (adjacent free segments are
//!    merged) and for NextFit traversal.
//!
//! 2. Power-of-two free lists: an array of 64 lists, where bucket n holds free
//!    segments whose size falls in [2^n, 2^(n+1)).
//!
//! 3. Allocated segment RB-tree: a tree of allocated segments keyed by base address.
//!    Used for O(log n) lookup on free() given only an address.
//!
//! ## Allocation
//!
//! Three policies are supported:
//!
//! - `InstantFit`: find the first segment in the appropriate freelist bucket. O(1) for
//!   unconstrained allocations; degrades under alignment or address constraints.
//!
//! - `BestFit`: scan freelist buckets for the smallest segment that satisfies the
//!   request. Minimizes fragmentation at the cost of a fuller scan.
//!
//! - `NextFit`: continue searching from where the last allocation left off, wrapping
//!   around at the end of the arena. Avoids reusing recently-freed addresses, making
//!   it useful for resources like PIDs where cycling through values is desirable.
//!
//! ## Differences from the original paper
//!
//! This implementation omits several features from the original Solaris vmem:
//!   - No importing: arenas are initialized with a fixed set of spans and cannot
//!     grow by importing from a parent arena. This simplifies the implementation
//!     significantly and is sufficient for fixed virtual address space management.
//!
//!   - No span markers: without importing there is no need to track which spans
//!     were imported, so span segment types are omitted entirely.
//!
//!   - No quantum caching: the original vmem uses per-size slab caches (qcaches)
//!     to accelerate small allocations. This is unnecessary here because vmem is
//!     only called by the slab allocator for large slab-sized chunks, not for
//!     individual small objects. This could change in the future if we find
//!     more uses for the allocator.
//!
//!   - No hash table: allocated segments are tracked in an RB-tree rather than
//!     the dynamic hash table used by Solaris vmem, avoiding the resize
//!     complexity.
const std = @import("std");
const rtl = @import("rtl");
const mm = @import("base").mm;
const mi = mm.private;

pub const Policy = enum {
    /// Use the smallest free segment that can satisfy the request.
    /// This tends to minimize fragmentation.
    BestFit,

    /// Provide a good approximation of the best fit policy in guaranteed
    /// O(1) time. This is the default policy.
    InstantFit,

    /// Use the next free segment after the most recently allocated segment.
    NextFit,
};

pub const AllocOptions = struct {
    policy: Policy = .InstantFit,
    alignment: ?usize = null,
    min: ?usize = null,
    max: ?usize = null,
};

const Segment = struct {
    const Type = enum {
        Allocated,
        Free,
    };

    const Linkage = union {
        /// Linkage into a freelist, valid when type == .Free
        free_link: rtl.List.Entry,
        /// Linkage into the allocated segments tree, valid when type == .Allocated
        tree_link: rtl.bst.Node,
    };
    /// The type of the segment.
    type: Type,
    /// The base address of the segment.
    base: usize,
    /// The size of the segment in bytes.
    size: usize,
    /// Linkage into the arena's segment list
    link: rtl.List.Entry,
    /// Type-specific linkage.
    linkage: Linkage,

    fn from_free_link(entry: *rtl.List.Entry) *Segment {
        const linkage: *Segment.Linkage = @fieldParentPtr("free_link", entry);
        return @fieldParentPtr("linkage", linkage);
    }

    fn from_tree_link(node: *rtl.bst.Node) *Segment {
        const linkage: *Segment.Linkage = @fieldParentPtr("tree_link", node);
        return @fieldParentPtr("linkage", linkage);
    }

    fn cmp(a_node: *rtl.bst.Node, b_node: *rtl.bst.Node) std.math.Order {
        const a: *Segment = Segment.from_tree_link(a_node);
        const b: *Segment = Segment.from_tree_link(b_node);
        return std.math.order(a.base, b.base);
    }
};

/// One freelist for each power of two size that can fit within the host's
/// address space.
const freelist_count = @bitSizeOf(usize);

var seg_zone: mi.zone.TypedZone(Segment) = undefined;

pub const Arena = struct {
    /// Name of the arena, for debugging purposes.
    name: []const u8,
    /// Start of initial span.
    base: usize,
    /// Size of initial span.
    size: usize,
    /// Unit of currency.
    quantum: usize,
    /// List of segments, sorted by base address.
    list: rtl.List,
    /// Power of two freelists for free segments, indexed by log2(size).
    freelists: [freelist_count]rtl.List,
    /// Tree for allocated segments, indexed by base address.
    allocated_segments: rtl.RBTree(Segment.cmp),
    /// Last segment allocated from, for NextFit policy.
    rotor: ?*Segment,

    const Self = @This();

    /// Initialize the area for use.
    pub fn init(self: *Self, name: []const u8, base: usize, size: usize, quantum: usize) !void {
        self.name = name;
        self.base = base;
        self.size = size;
        self.quantum = quantum;

        rtl.List.init(&self.list);

        for (&self.freelists) |*freelist| {
            freelist.init();
        }

        self.allocated_segments = .init();
        self.rotor = null;

        // Add initial span
       try self.add(base, size);
    }

    pub fn deinit(self: *Self) void {
        // free all segments in the segment list
        var entry = self.list.first();
        while (entry != &self.list.head) {
            const next = entry.next;
            const seg: *Segment = @fieldParentPtr("link", entry);
            free_segment(seg);
            entry = next;
        }
    }

    /// Add a span of memory to the arena.
    pub fn add(self: *Self, addr: usize, size: usize) !void {
        const new_seg = try self.alloc_segment();
        new_seg.* = Segment{
            .type = .Free,
            .base = addr,
            .size = size,
            .link = undefined,
            .linkage = .{ .free_link = undefined },
        };

        // Insert into segment list, sorted by base address.
        // Start from the end since we're likely to be adding higher addresses.
        var entry = self.list.last();
        while (entry != &self.list.head) {
            const s: *Segment = @fieldParentPtr("link", entry);
            if (s.base < addr) break;
            entry = entry.prev;
        }

        new_seg.link.insert_before(entry.next);
        self.add_segment_to_freelist(new_seg);
    }

    /// Allocate a segment of memory from the arena.
    /// Options:
    /// - policy: allocation policy to use. Default is .InstantFit.
    /// - alignment: if specified, the returned segment will be aligned to this boundary.
    /// - min: if specified, the returned segment will be at least on this address.
    /// - max: if specified, the returned segment will be at most on this address.
    /// Returns the base address of the allocated segment.
    pub fn alloc(
        self: *Self,
        size: usize,
        options: AllocOptions,
    ) mm.Error!usize {
        if (size % self.quantum != 0) {
            return error.InvalidSize;
        }

        const result = switch (options.policy) {
            .InstantFit => self.instant_fit(size, options),
            .BestFit => self.best_fit(size, options),
            .NextFit => self.next_fit(size, options),
        };

        const start, var seg = result orelse return error.OutOfMemory;

        std.debug.assert(seg.type == .Free);
        std.debug.assert(seg.size >= size);

        // Remove the segment from the freelist.
        self.remove_segment_from_freelist(seg);

        // left split: alignment pushed start forward, so there's a gap between
        // seg.base and start that needs to become a free segment.
        // e.g. seg=[0x0, 0x10000], start=0x100:
        //   before: [0x0, 0x10000] free
        //   after:  [0x0, 0x100] free, [0x100, 0x10000] being processed
        if (seg.base != start) {
            const left_seg = try self.alloc_segment();
            left_seg.* = Segment{
                .type = .Free,
                .base = seg.base,
                .size = start - seg.base,
                .link = undefined,
                .linkage = .{ .free_link = undefined },
            };

            seg.base = start;
            seg.size -= left_seg.size;

            left_seg.link.insert_before(&seg.link);
            self.add_segment_to_freelist(left_seg);
        }

        // right split: seg is larger than needed, so split into allocated + free remainder.
        // e.g. seg=[0x100, 0x10000], size=0x1000:
        //   before: [0x100, 0x10000] being processed
        //   after:  [0x100, 0x1100] allocated, [0x1100, 0x10000] free
        // the quantum check avoids creating a remainder too small to ever be useful.
        if (seg.size != size and (seg.size - size) > self.quantum - 1) {
            const new_seg = try self.alloc_segment();
            new_seg.* = .{ .type = .Allocated, .base = seg.base, .size = size, .link = undefined, .linkage = .{ .tree_link = undefined } };

            seg.base += size;
            seg.size -= size;
            seg.type = .Free;
            seg.linkage = .{ .free_link = undefined };

            new_seg.link.insert_before(&seg.link);
            self.add_segment_to_freelist(seg);

            self.allocated_segments.insert(&new_seg.linkage.tree_link) catch return error.InvalidAddress;

            if (options.policy == .NextFit) self.rotor = new_seg;
            return new_seg.base;
        } else {
            // seg is exactly the right size (or remainder is too small), use it directly.
            seg.type = .Allocated;
            seg.linkage = .{ .tree_link = undefined };
            self.allocated_segments.insert(&seg.linkage.tree_link) catch return error.InvalidAddress;

            if (options.policy == .NextFit) self.rotor = seg;
            return seg.base;
        }
    }

    pub fn free(self: *Self, addr: usize, size: usize) mm.Error!void {
        // Find the allocated segment containing addr.
        var search_node = Segment{
            .type = .Allocated,
            .base = addr,
            .size = 0,
            .link = undefined,
            .linkage = .{ .tree_link = undefined },
        };

        const node = self.allocated_segments.tree.search(&search_node.linkage.tree_link) orelse return error.InvalidAddress;

        const seg = Segment.from_tree_link(node);

        if (seg.size != size) return error.InvalidAddress;

        // Remove from allocated tree.
        self.allocated_segments.delete(node);

        // Coalesce to the right.
        const next_entry = seg.link.next;
        if (next_entry != &self.list.head) {
            const next_seg: *Segment = @fieldParentPtr("link", next_entry);

            if (self.rotor == next_seg) self.rotor = seg;

            if (next_seg.type == .Free) {
                // Remove next segment from freelist and segment list, then merge into seg.
                self.remove_segment_from_freelist(next_seg);
                next_seg.link.remove();
                seg.size += next_seg.size;
                self.free_segment(next_seg);
            }
        }

        // Coalesce to the left.
        const prev_entry = seg.link.prev;
        if (prev_entry != &self.list.head) {
            const prev_seg: *Segment = @fieldParentPtr("link", prev_entry);

            if (self.rotor == prev_seg) self.rotor = seg;

            if (prev_seg.type == .Free) {
                // Remove previous segment from freelist and segment list, then merge into seg.
                self.remove_segment_from_freelist(prev_seg);
                prev_seg.link.remove();
                seg.base = prev_seg.base;
                seg.size += prev_seg.size;
                self.free_segment(prev_seg);
            }
        }

        // Mark as free and add to freelist.
        seg.type = .Free;
        seg.linkage = .{ .free_link = undefined };
        self.add_segment_to_freelist(seg);
    }

    // Implementation for the instant fit policy.
    fn instant_fit(self: *Self, size: usize, options: AllocOptions) ?struct { usize, *Segment } {
        var idx = freelist_index(size);

        if (!std.math.isPowerOfTwo(size)) idx += 1;

        // Simply grab the first segment from the appropriate freelist
        // that can satisfy the request.
        // This is O(1) unless there are contraints.
        while (idx < freelist_count) : (idx += 1) {
            var it = self.freelists[idx].iterator();
            while (it.next()) : (it.advance()) {
                const seg = Segment.from_free_link(it.get());
                if (self.try_to_fit(seg, size, options)) |addr| return .{ addr, seg };
            }
        }
        return null;
    }

    // Implementation for the best fit policy.
    // Find the smallest segment that can satisfy the request.
    fn best_fit(self: *Self, size: usize, options: AllocOptions) ?struct { usize, *Segment } {
        var idx = freelist_index(size);
        var best_seg: ?*Segment = null;
        var best_start: usize = 0;

        while (idx < freelist_count) : (idx += 1) {
            var it = self.freelists[idx].iterator();

            while (it.next()) : (it.advance()) {
                const seg = Segment.from_free_link(it.get());
                if (self.try_to_fit(seg, size, options)) |addr| {
                    if (best_seg == null or seg.size < best_seg.?.size) {
                        best_seg = seg;
                        best_start = addr;
                    }
                }
            }

            if (best_seg != null) break;
        }
        return if (best_seg) |s| .{ best_start, s } else null;
    }

    // Implementation for the next fit policy.
    // Continue searching from the last allocated segment, wrapping around at the end of the arena.
    fn next_fit(self: *Self, size: usize, options: AllocOptions) ?struct { usize, *Segment } {
        // Start from rotor if we have one, otherwise from the beginning.
        const start_entry = if (self.rotor) |r| r.link.next else self.list.first();

        // Search from rotor to end of list.
        var entry = start_entry;
        while (entry != &self.list.head) : (entry = entry.next) {
            const seg: *Segment = @fieldParentPtr("link", entry);
            if (seg.type != .Free) continue;
            if (self.try_to_fit(seg, size, options)) |addr| {
                return .{ addr, seg };
            }
        }

        // Wrap around and search from beginning to rotor.
        entry = self.list.first();
        while (entry != start_entry) : (entry = entry.next) {
            const seg: *Segment = @fieldParentPtr("link", entry);
            if (seg.type != .Free) continue;
            if (self.try_to_fit(seg, size, options)) |addr| {
                return .{ addr, seg };
            }
        }

        return null;
    }

    // Try to fit the given segment to the request with the given options.
    // Returns the fitted address if successful.
    fn try_to_fit(self: *Self, segment: *Segment, size: usize, options: AllocOptions) ?usize {
        var start = @max(segment.base, options.min orelse 0);
        const end = @min(segment.base + segment.size, options.max orelse std.math.maxInt(usize));
        const alignment = options.alignment orelse self.quantum;

        if (start > end) return null;

        // Align start to the required alignment.
        start = std.mem.alignForward(usize, start, alignment);

        if (start + size <= end) {
            return start;
        }

        return null;
    }

    fn alloc_segment(self: *Self) !*Segment {
        _ = self;
        return seg_zone.create();
    }

    fn free_segment(self: *Self, segment: *Segment) void {
        seg_zone.destroy(segment);
        _ = self;
    }

    fn add_segment_to_freelist(self: *Self, segment: *Segment) void {
        const freelist = self.freelist_for_size(segment.size);
        freelist.insert_tail(&segment.linkage.free_link);
    }

    fn remove_segment_from_freelist(self: *Self, segment: *Segment) void {
        _ = self;
        segment.linkage.free_link.remove();
    }

    inline fn freelist_index(size: usize) usize {
        return std.math.log2_int(usize, size);
    }

    inline fn freelist_for_size(self: *Self, size: usize) *rtl.List {
        return &self.freelists[freelist_index(size)];
    }
};

pub fn init() void {
    seg_zone.init("seg", .{});
}
