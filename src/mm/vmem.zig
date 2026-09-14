//! Generic resource allocator, based on the vmem allocator described in:
//! Jeff Bonwick and Jonathan Adams'
//! "Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources"
const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const mm = r.mm;
const mmp = mm.private;
const ke = r.ke;

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
        Span,
        SpanImported,
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

    fn cmp(
        a_node: *const rtl.bst.Node,
        b_node: *const rtl.bst.Node,
    ) std.math.Order {
        const a = Segment.from_tree_link(@constCast(a_node));
        const b = Segment.from_tree_link(@constCast(b_node));
        return std.math.order(a.base, b.base);
    }
};

/// One freelist for each power of two size that can fit within the host's
/// address space.
const freelist_count = @bitSizeOf(usize);
const max_qcaches = 16;

var seg_zone: mmp.zone.TypedZone(Segment) = undefined;

pub const Arena = struct {
    /// Name of the arena, for debugging purposes.
    name: []const u8,
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
    /// Maximum size (**in bytes**) to do quantum caching on.
    qcache_max: usize,
    /// Quantum caches.
    qcaches: [max_qcaches]*mm.zone.Zone,
    /// Quantum size shift.
    qshift: std.math.Log2Int(usize),

    /// Backing arena.
    source: ?Source,

    lock: ke.Mutex,

    const Self = @This();

    const Span = struct { addr: usize, size: usize };

    const Source = struct {
        arena: *Self,
        import: *const fn (*Self, usize, opts: AllocOptions) mm.Error!usize,
        release: *const fn (*Self, addr: usize, size: usize) void,
    };

    const InitOptions = struct {
        span: ?Span,
        quantum: usize,
        cache_max_quanta: ?usize = null,
        source: ?Source = null,
    };

    /// Initialize the area for use.
    pub fn init(
        self: *Self,
        name: []const u8,
        opts: InitOptions,
    ) !void {
        self.name = name;
        self.quantum = opts.quantum;
        self.qcache_max = (opts.cache_max_quanta orelse 0) * opts.quantum;
        self.source = opts.source;

        rtl.assert(
            std.math.isPowerOfTwo(opts.quantum),
            "Arena init: quantum not a power-of-two: {}",
            .{opts.quantum},
        );

        self.qshift = std.math.log2_int(usize, self.quantum);

        if (opts.span == null) {
            rtl.assert(opts.source != null, "Arena init: null span without source", .{});
        }

        self.list.init();

        for (&self.freelists) |*freelist| {
            freelist.init();
        }

        if (opts.cache_max_quanta) |qc| {
            const num_qcaches = @min(qc, max_qcaches);

            for (0..num_qcaches) |i| {
                const size = (i + 1) * opts.quantum;

                self.qcaches[i] = mm.zone.gpa.create(mm.zone.Zone) catch
                    unreachable;

                self.qcaches[i].init(name, size, .{
                    .import = vmem_zone_import,
                    .release = vmem_zone_release,
                    .arg = self,
                });
            }
        }

        self.lock = .init();

        self.allocated_segments = .init();
        self.rotor = null;

        // Add initial span.
        if (opts.span) |sp| {
            try self.add(sp);
        }
    }

    pub fn deinit(self: *Self) void {
        // Free all segments in the segment list
        var entry = self.list.first();
        while (entry != &self.list.head) {
            const next = entry.next;
            const seg: *Segment = @fieldParentPtr("link", entry);
            free_segment(seg);
            entry = next;
        }
    }

    /// Add a span of memory to the arena.
    pub fn add(self: *Self, span: Span) !void {
        return self.add_opts(span, .Span);
    }

    /// Add a span of memory to the arena.
    fn add_opts(self: *Self, span: Span, kind: Segment.Type) mm.Error!void {
        const new_free_seg = try self.alloc_segment();

        new_free_seg.* = Segment{
            .type = .Free,
            .base = span.addr,
            .size = span.size,
            .link = undefined,
            .linkage = .{ .free_link = undefined },
        };

        const new_span_seg = try self.alloc_segment();

        new_span_seg.* = Segment{
            .type = kind,
            .base = span.addr,
            .size = span.size,
            .link = undefined,
            .linkage = .{ .free_link = undefined },
        };

        self.list.insert_tail(&new_span_seg.link);
        self.list.insert_tail(&new_free_seg.link);

        self.add_segment_to_freelist(new_free_seg);
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
        if (size & self.qshift != 0) {
            return error.InvalidSize;
        }

        if (size <= self.qcache_max) {
            const i = size >> self.qshift;
            const ret = try self.qcaches[i - 1].alloc(.{});
            return @intFromPtr(ret);
        }

        self.lock.acquire();
        defer self.lock.release();

        return self.alloc_impl(size, options);
    }

    fn alloc_impl(
        self: *Self,
        size: usize,
        options: AllocOptions,
    ) mm.Error!usize {
        if (size & self.quantum != 0) {
            return error.InvalidSize;
        }

        const result = blk: while (true) {
            const ret = switch (options.policy) {
                .InstantFit => self.instant_fit(size, options),
                .BestFit => self.best_fit(size, options),
                .NextFit => self.next_fit(size, options),
            };

            if (ret != null) break :blk ret.?;

            if (ret == null) {
                try self.import(size, options);
            }

            // This is guaranteed to terminate eventually, either when the import
            // brings in new free memory, or when it runs out.
        };

        const start, var seg = result;

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
            new_seg.* = .{
                .type = .Allocated,
                .base = seg.base,
                .size = size,
                .link = undefined,
                .linkage = .{ .tree_link = undefined },
            };

            seg.base += size;
            seg.size -= size;
            seg.type = .Free;
            seg.linkage = .{ .free_link = undefined };

            new_seg.link.insert_before(&seg.link);
            self.add_segment_to_freelist(seg);

            self.allocated_segments.insert(&new_seg.linkage.tree_link) catch
                return error.InvalidAddress;

            if (options.policy == .NextFit) self.rotor = new_seg;
            return new_seg.base;
        } else {
            // seg is exactly the right size (or remainder is too small),
            // use it directly.
            seg.type = .Allocated;
            seg.linkage = .{ .tree_link = undefined };
            self.allocated_segments.insert(&seg.linkage.tree_link) catch
                return error.InvalidAddress;

            if (options.policy == .NextFit) self.rotor = seg;
            return seg.base;
        }
    }

    /// Try to import memory from the parent arena.
    fn import(self: *Self, size: usize, options: AllocOptions) mm.Error!void {
        const src = self.source orelse return error.OutOfMemory;

        // Ensure no funny stuff happens wrt the lock.
        self.lock.release();

        const ret = src.import(src.arena, size, options);

        self.lock.acquire();
        const addr = try ret;

        try self.add_opts(
            .{ .addr = addr, .size = size },
            .SpanImported,
        );
    }

    pub fn free(self: *Self, addr: usize, size: usize) void {
        if (size <= self.qcache_max) {
            const i = size >> self.qshift;
            self.qcaches[i - 1].free(@ptrFromInt(addr));
            return;
        }

        self.lock.acquire();
        defer self.lock.release();

        return self.free_impl(addr, size);
    }

    fn free_impl(self: *Self, addr: usize, size: usize) void {

        // Find the allocated segment containing addr.
        var search_node = Segment{
            .type = .Allocated,
            .base = addr,
            .size = 0,
            .link = undefined,
            .linkage = .{ .tree_link = undefined },
        };

        const node = self.allocated_segments.tree.search(
            &search_node.linkage.tree_link,
        ) orelse std.debug.panic(
            "vmem \"{s}\": bad free address: addr={x} size={x}",
            .{ self.name, addr, size },
        );

        const seg = Segment.from_tree_link(node);

        if (seg.size != size) {
            std.debug.panic(
                "vmem \"{s}\": bad free size addr={x} sz={x}, expected={x}",
                .{ self.name, addr, size, seg.size },
            );
        }

        // Remove from allocated tree.
        self.allocated_segments.delete(node);

        // Coalesce to the right.
        const next_entry = seg.link.next;
        if (next_entry != &self.list.head) {
            const next_seg: *Segment = @fieldParentPtr("link", next_entry);

            if (next_seg.type == .Free) {
                // Remove next segment from freelist and segment list,
                // then merge into seg.
                self.remove_segment_from_freelist(next_seg);
                next_seg.link.remove();
                seg.size += next_seg.size;

                if (self.rotor == next_seg) self.rotor = seg;
                self.free_segment(next_seg);
            }
        }

        // Coalesce to the left.
        const prev_entry = seg.link.prev;
        if (prev_entry != &self.list.head) {
            const prev_seg: *Segment = @fieldParentPtr("link", prev_entry);

            if (prev_seg.type == .Free) {
                // Remove previous segment from freelist and segment list,
                // then merge into seg.
                self.remove_segment_from_freelist(prev_seg);
                prev_seg.link.remove();
                seg.base = prev_seg.base;
                seg.size += prev_seg.size;

                if (self.rotor == prev_seg) self.rotor = seg;
                self.free_segment(prev_seg);
            }
        }

        if (!self.release(seg)) {
            // Mark as free and add to freelist.
            seg.type = .Free;
            seg.linkage = .{ .free_link = undefined };
            self.add_segment_to_freelist(seg);
        }
    }

    /// Try to release a segment back to its source.
    fn release(self: *Self, seg: *Segment) bool {
        const prev_entry = seg.link.prev;

        if (prev_entry == &self.list.head) {
            return false;
        }

        const src = self.source orelse return false;
        const prev_seg: *Segment = @fieldParentPtr("link", prev_entry);

        if (prev_seg.type == .SpanImported and prev_seg.size == seg.size) {
            // The imported span is completely free, return it to its parent.
            prev_seg.link.remove();
            seg.link.remove();

            const addr = seg.base;
            const size = seg.size;

            self.free_segment(prev_seg);
            self.free_segment(seg);

            src.release(src.arena, addr, size);
            return true;
        }

        return false;
    }

    // Implementation for the instant fit policy.
    fn instant_fit(
        self: *Self,
        size: usize,
        options: AllocOptions,
    ) ?struct { usize, *Segment } {
        const is_pow2 = std.math.isPowerOfTwo(size);
        const orig_idx = freelist_index(size);

        var idx = orig_idx;

        if (!is_pow2) idx += 1;

        // Simply grab the first segment from the appropriate freelist
        // that can satisfy the request.
        // This is O(1) unless there are constraints.
        while (idx < freelist_count) : (idx += 1) {
            var it = self.freelists[idx].iterator();
            while (it.next()) : (it.advance()) {
                const seg = Segment.from_free_link(it.get());
                if (self.try_to_fit(seg, size, options)) |addr|
                    return .{ addr, seg };
            }
        }

        // If we found nothing and it's not a power of two, there may still be
        // something in the lower freelist, so check there.
        // This is O(n) but should happen very rarely.
        if (!is_pow2) {
            std.debug.assert(orig_idx != 0);

            var it = self.freelists[orig_idx].iterator();
            while (it.next()) : (it.advance()) {
                const seg = Segment.from_free_link(it.get());
                if (self.try_to_fit(seg, size, options)) |addr|
                    return .{ addr, seg };
            }
        }

        return null;
    }

    // Implementation for the best fit policy.
    // Find the smallest segment that can satisfy the request.
    fn best_fit(
        self: *Self,
        size: usize,
        options: AllocOptions,
    ) ?struct { usize, *Segment } {
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
    // Continue searching from the last allocated segment, wrapping around at
    // the end of the arena.
    fn next_fit(
        self: *Self,
        size: usize,
        options: AllocOptions,
    ) ?struct { usize, *Segment } {
        // Start from rotor if we have one, otherwise from the beginning.
        const start_entry = if (self.rotor) |ro| ro.link.next else self.list.first();

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
    fn try_to_fit(
        self: *Self,
        segment: *const Segment,
        size: usize,
        options: AllocOptions,
    ) ?usize {
        var start = @max(segment.base, options.min orelse 0);
        const end = @min(segment.base + segment.size, options.max orelse
            std.math.maxInt(usize));
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

fn vmem_zone_import(
    arg: ?*anyopaque,
    elems: []*anyopaque,
    elem_size: usize,
    policy: mm.WaitPolicy,
) mm.Error!usize {
    const self: *Arena = @ptrCast(@alignCast(arg));

    _ = policy;

    self.lock.acquire();

    for (0..elems.len) |i| {
        elems[i] = @ptrFromInt(self.alloc_impl(
            elem_size,
            .{},
        ) catch |err| {
            if (i != 0) return i;
            return err;
        });
    }

    self.lock.release();

    return elems.len;
}

fn vmem_zone_release(
    arg: ?*anyopaque,
    elems: []*anyopaque,
    elem_size: usize,
) void {
    const self: *Arena = @ptrCast(@alignCast(arg));

    self.lock.acquire();

    for (elems) |elem| {
        self.free_impl(@intFromPtr(elem), elem_size);
    }

    self.lock.release();
}

pub fn init() void {
    seg_zone.init("seg", .{});
}
