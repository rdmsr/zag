//! Slab allocator implementation with per-CPU object caching.
//! As described in Bonwick's "The Slab Allocator: An Object-Caching Kernel Memory Allocator"
//! and "Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources".
//! Additions to the allocator were inspired by FreeBSD:
//! - A pointer to the slab metadata is stored in the struct page for out-of-line slabs.
//! - bufctls are omitted and instead a bitmap is used.
//! - Separate alloc/free magazines.
const rtl = @import("rtl");
const r = @import("root");
const config = @import("config");
const std = @import("std");
const ke = r.ke;
const mm = r.mm;
const mi = mm.private;

/// A slab is a contiguous memory region that holds multiple objects of the same type.
const Slab = struct {
    /// Linkage into a zone's list of slabs.
    link: rtl.List.Entry,
    /// Reference count indicating how many objects are in use.
    refcount: u16,
    capacity: u16,
    /// Base address of the slab + its color.
    base: usize,
    /// Base address of the slab allocation.
    buf: usize,

    pub fn bitmap(self: *Slab) [*]u64 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Slab));
    }

    pub fn bitmap_bytes(capacity: usize) usize {
        return std.mem.alignForward(usize, capacity, 64) / 8;
    }

    /// Allocates a free bit from the bitmap, returns the allocated bit.
    pub fn bitmap_alloc(self: *Slab) ?u16 {
        const bitmaps = std.mem.alignForward(usize, self.capacity, 64) / 64;
        for (0..bitmaps) |i| {
            const chunk = self.bitmap()[i];
            if (chunk == 0) continue;
            const bit = @ctz(chunk);

            self.bitmap()[i] &= ~(@as(u64, 1) << @intCast(bit));
            return @intCast((i * 64) + bit);
        }

        return null;
    }

    /// Free a bit to the bitmap.
    pub fn bitmap_free(self: *Slab, idx: usize) void {
        const bm = self.bitmap();
        bm[idx / 64] |= @as(u64, 1) << @intCast(idx % 64);
    }

    /// Check whether or not the slab is completely empty.
    pub fn bitmap_all_free(self: *Slab) bool {
        const full_words = self.capacity / 64;
        const bm = self.bitmap();

        for (0..full_words) |i| {
            if (bm[i] != std.math.maxInt(u64)) return false;
        }

        const rem = self.capacity % 64;
        if (rem > 0) {
            const mask = (@as(u64, 1) << @intCast(rem)) - 1;
            if (bm[full_words] & mask != mask) return false;
        }
        return true;
    }

    /// Return the appropriate slab size for a given chunk size.
    pub fn calc_slab_size(chunk_size: usize) usize {
        // Try increasing page multiples until waste is under 12.5%.
        var order: u5 = 0;
        while (order <= 8) : (order += 1) {
            const slab_size = @as(usize, mm.page_size) << order;
            const n_objs = slab_size / chunk_size;
            if (n_objs == 0) continue;
            const waste = slab_size - (n_objs * chunk_size);
            // Accept if waste < 1/8th of slab.
            if (waste * 8 <= slab_size) return slab_size;
        }
        // Fallback: just fit one object, rounded up to page boundary
        return std.mem.alignForward(usize, chunk_size, mm.page_size);
    }

    /// Calculates how many objects fit in a small slab page, accounting for the
    /// fact that the bitmap size grows with capacity (making this circular).
    /// We resolve the circular dependency by starting with an overestimate and
    /// shrinking until everything fits.
    pub fn calc_capacity(chunk_size: usize, color: usize) usize {
        const usable = mm.page_size - @sizeOf(Slab) - color;

        // Start with the largest possible capacity.
        var capacity = (usable - 1) / chunk_size;

        // Shrink capacity until both the objects and the bitmap fit.
        // Each iteration we recalculate the bitmap size for the new capacity,
        // since a smaller capacity means a smaller bitmap, which may then fit.
        while (capacity > 0) : (capacity -= 1) {
            const obj_bytes = capacity * chunk_size;
            const bytes = Slab.bitmap_bytes(capacity);
            if (obj_bytes + bytes <= usable) break;
        }

        return capacity;
    }
};

/// A magazine is a per-CPU cache of objects for a zone.
const Magazine = struct {
    /// Next magazine in the list.
    next: ?*Magazine,
    /// Rounds follow in memory after the struct.
    pub fn rounds_ptr(self: *Magazine) [*]*anyopaque {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Magazine));
    }
};

const MagazineType = struct {
    rounds: usize,
    alignment: usize,
    minbuf: usize,
    maxbuf: usize,
    /// Magazine zone.
    zone: Zone,
};

/// Per-CPU state for a zone.
const Cpu = struct {
    lock: ke.SpinLock,
    /// Magazine used for allocations.
    alloc: ?*Magazine,
    /// Magazine used for frees.
    free: ?*Magazine,
    /// Number of rounds in alloc magazine.
    alloc_rounds: usize,
    /// Number of rounds in free magazine.
    free_rounds: usize,
    /// Number of rounds in a full magazine.
    magazine_size: usize,
};

pub const Page = extern struct {
    slab: *Slab,
};

const initial_hash = 32;

const slab_align = 8;

/// Global count of zones.
const zones_num = 32;

/// Every power-of-two-size from 8 to 2048 (inclusively).
const generic_zones_num = 9;

const generic_zone_names = [_][]const u8{
    "zone-8",
    "zone-16",
    "zone-32",
    "zone-64",
    "zone-128",
    "zone-256",
    "zone-512",
    "zone-1024",
    "zone-2048",
};

/// 1/8th of a page.
const small_slab_size = 512;

/// Generic zones for power-of-two sizes from 8 to 2048.
var generic_zones: [generic_zones_num]Zone = undefined;

var magazines_initialized = false;
var all_zones: ?*Zone = null;

var magtypes = [_]MagazineType{
    .{ .rounds = 1, .alignment = 8, .minbuf = 3200, .maxbuf = 65536, .zone = undefined },
    .{ .rounds = 3, .alignment = 16, .minbuf = 256, .maxbuf = 32768, .zone = undefined },
    .{ .rounds = 7, .alignment = 32, .minbuf = 64, .maxbuf = 16384, .zone = undefined },
    .{ .rounds = 15, .alignment = 64, .minbuf = 0, .maxbuf = 8192, .zone = undefined },
    .{ .rounds = 31, .alignment = 64, .minbuf = 0, .maxbuf = 4096, .zone = undefined },
    .{ .rounds = 47, .alignment = 64, .minbuf = 0, .maxbuf = 2048, .zone = undefined },
    .{ .rounds = 63, .alignment = 64, .minbuf = 0, .maxbuf = 1024, .zone = undefined },
    .{ .rounds = 95, .alignment = 64, .minbuf = 0, .maxbuf = 512, .zone = undefined },
    .{ .rounds = 143, .alignment = 64, .minbuf = 0, .maxbuf = 0, .zone = undefined },
};

const alloc_poison: u32 = 0xBADDC0DE;
const free_poison: u32 = 0xDEADBEEF;
const is_poison_enabled = config.slab_poison;
const should_check_poison = config.slab_check_poison;

inline fn fill_with_poison(ptr: *anyopaque, len: usize, pattern: u32) void {
    const bytes: [*]u8 = @ptrCast(ptr);
    var i: usize = 0;

    while (i + 4 <= len) : (i += 4) {
        std.mem.writeInt(u32, bytes[i..][0..4], pattern, .little);
    }

    if (i < len) {
        var tail: [4]u8 = undefined;
        std.mem.writeInt(u32, &tail, pattern, .little);
        var j: usize = 0;
        while (i < len) : ({
            i += 1;
            j += 1;
        }) bytes[i] = tail[j];
    }
}

inline fn check_poison(ptr: *anyopaque, len: usize, pattern: u32) bool {
    if (!should_check_poison) return true;

    const bytes: [*]const u8 = @ptrCast(ptr);
    var i: usize = 0;

    while (i + 4 <= len) : (i += 4) {
        if (std.mem.readInt(u32, bytes[i..][0..4], .little) != pattern) return false;
    }

    if (i < len) {
        var tail: [4]u8 = undefined;
        std.mem.writeInt(u32, &tail, pattern, .little);
        var j: usize = 0;
        while (i < len) : ({
            i += 1;
            j += 1;
        }) {
            if (bytes[i] != tail[j]) return false;
        }
    }

    return true;
}

pub const Zone = struct {
    /// Name used for debugging purposes.
    name: []const u8,
    /// Size of objects in this zone.
    obj_size: usize,
    /// Alignment of objects in this zone.
    alignment: usize,
    /// Size of a slab.
    slab_size: usize,
    /// Size of a chunk.
    chunk_size: usize,
    /// Offset for buf-to-bufctl conversion.
    offset: usize,
    /// Max color for slab coloring.
    max_color: usize,
    /// Current color for slab coloring.
    color: usize,
    /// Zone lock.
    lock: ke.QSpinLock,
    /// List of full slabs in this zone.
    full_slabs: rtl.List,
    /// List of partial slabs in this zone.
    partial_slabs: rtl.List,
    /// Linkage into the global zone list.
    next: ?*Zone,
    depot_lock: ke.QSpinLock,

    empty_mags: ?*Magazine,
    full_mags: ?*Magazine,
    magtype: ?*MagazineType,
    /// Per-CPU state.
    cpus: []Cpu,

    ctor: ?*const fn (obj: *anyopaque) void,
    dtor: ?*const fn (obj: *anyopaque) void,

    use_magazines: bool,

    const Self = @This();

    pub const InitOptions = struct {
        alignment: usize = 0,
        ctor: ?*const fn (*anyopaque) void = null,
        dtor: ?*const fn (*anyopaque) void = null,
        magazines: bool = true,
    };

    /// Initialize a zone.
    pub fn init(self: *Self, name: []const u8, size: usize, options: InitOptions) void {
        const obj_align = if (options.alignment == 0) slab_align else options.alignment;
        const chunk_size = std.mem.alignForward(usize, size, obj_align);

        const slab_size, const max_color = if (size <= small_slab_size) blk: {
            const ss = mm.page_size;
            break :blk .{ ss, @rem(ss - @sizeOf(Slab), chunk_size) };
        } else blk: {
            const ss = Slab.calc_slab_size(chunk_size);
            break :blk .{ ss, @rem(ss, chunk_size) };
        };

        self.full_slabs.init();
        self.partial_slabs.init();

        self.name = name;
        self.obj_size = size;
        self.alignment = obj_align;
        self.slab_size = slab_size;
        self.chunk_size = chunk_size;
        self.max_color = max_color;
        self.color = 0;
        self.ctor = options.ctor;
        self.dtor = options.dtor;
        self.lock = .init();
        self.use_magazines = options.magazines;

        const prev = all_zones;
        all_zones = self;
        self.next = prev;

        self.magtype = null;
        for (&magtypes) |*mtype| {
            if (chunk_size > mtype.minbuf and chunk_size <= mtype.maxbuf) {
                self.magtype = mtype;
                break;
            }
        }

        if (!magazines_initialized) {
            return;
        }

        self.cpus = gpa.alloc(Cpu, ke.ncpus) catch @panic("Failed to allocate per-CPU magazine state");

        for (0..ke.ncpus) |i| {
            self.cpus[i].lock = .init();
            self.cpus[i].alloc = null;
            self.cpus[i].free = null;
            self.cpus[i].alloc_rounds = 0;
            self.cpus[i].free_rounds = 0;
            self.cpus[i].magazine_size = self.magtype.?.rounds;
        }
    }

    /// Allocate an object from the zone.
    pub fn alloc(self: *Self) mm.Error!*anyopaque {
        const ipl = ke.ipl.raise(.Dispatch);
        defer ke.ipl.lower(ipl);
        var buf: *anyopaque = undefined;

        // Try grabbing an object from the magazine layer.
        if (magazines_initialized and self.use_magazines) {
            @branchHint(.likely);
            const cpu = &self.cpus[ke.cpu.current()];

            cpu.lock.acquire_no_ipl();
            defer cpu.lock.release_no_ipl();

            while (true) {
                if (cpu.alloc_rounds > 0) {
                    // Fast path: just pop from the alloc magazine.
                    cpu.alloc_rounds -= 1;
                    buf = cpu.alloc.?.rounds_ptr()[cpu.alloc_rounds];

                    if (is_poison_enabled) {
                        if (!check_poison(buf, self.obj_size, free_poison)) {
                            @panic("slab poison mismatch: object corrupted after free");
                        }

                        fill_with_poison(buf, self.obj_size, alloc_poison);

                        if (self.ctor) |ctor| {
                            ctor(buf);
                        }
                    }

                    return buf;
                }

                if (cpu.free_rounds > 0) {
                    std.debug.assert(cpu.free != null);

                    // Alloc magazine is empty. If the free magazine has items, swap them.
                    // The free magazine now becomes our alloc magazine.
                    std.mem.swap(?*Magazine, &cpu.alloc, &cpu.free);
                    std.mem.swap(usize, &cpu.alloc_rounds, &cpu.free_rounds);
                    continue;
                }

                // Both magazines are empty.
                // Try to get a full magazine from the depot.
                if (self.alloc_from_depot(&self.full_mags)) |full_mag| {
                    // Discard our empty alloc magazine to the depot.
                    if (cpu.alloc) |empty_mag| {
                        self.free_to_depot(empty_mag, &self.empty_mags);
                    }

                    cpu.alloc = full_mag;
                    cpu.alloc_rounds = cpu.magazine_size;
                    continue;
                }

                // Depot has no full magazines, fall back to the slab layer..
                break;
            }
        }

        // Fall back to the slab layer.
        self.lock.acquire_no_ipl();
        defer self.lock.release_no_ipl();

        var slab: *Slab = undefined;

        if (self.partial_slabs.is_empty()) {
            slab = try self.slab_create();
            self.partial_slabs.insert_tail(&slab.link);
        } else {
            slab = @fieldParentPtr("link", self.partial_slabs.first());
        }

        const idx = slab.bitmap_alloc() orelse return error.OutOfMemory;
        buf = @ptrFromInt(slab.base + idx * self.chunk_size);

        slab.refcount += 1;

        if (slab.refcount == slab.capacity) {
            slab.link.remove();
            self.full_slabs.insert_tail(&slab.link);
        }

        if (is_poison_enabled) {
            if (!check_poison(buf, self.obj_size, free_poison)) {
                @panic("slab poison mismatch: object corrupted after free");
            }

            fill_with_poison(buf, self.obj_size, alloc_poison);

            if (self.ctor) |ctor| {
                ctor(buf);
            }
        }

        return buf;
    }

    /// Free an object back to the zone.
    pub fn free(self: *Self, obj: *anyopaque) void {
        const ipl = ke.ipl.raise(.Dispatch);
        defer ke.ipl.lower(ipl);

        if (magazines_initialized and self.use_magazines) {
            @branchHint(.likely);

            const cpu = &self.cpus[ke.cpu.current()];

            cpu.lock.acquire_no_ipl();
            defer cpu.lock.release_no_ipl();

            while (true) {
                if (cpu.free != null and cpu.free_rounds < cpu.magazine_size) {
                    // Fast path: push directly to free magazine.
                    if (is_poison_enabled) {
                        if (self.dtor) |dtor| {
                            dtor(obj);
                        }

                        fill_with_poison(obj, self.obj_size, free_poison);
                    }

                    cpu.free.?.rounds_ptr()[cpu.free_rounds] = obj;
                    cpu.free_rounds += 1;
                    return;
                }

                if (cpu.alloc_rounds == 0 and cpu.alloc != null) {
                    // Free magazine is full. If the alloc magazine is completely empty, swap them.
                    // The empty alloc magazine becomes our new free magazine.
                    std.mem.swap(?*Magazine, &cpu.alloc, &cpu.free);
                    std.mem.swap(usize, &cpu.alloc_rounds, &cpu.free_rounds);
                    continue;
                }

                // Free magazine is full, and alloc magazine has items.
                // Try to get an empty magazine from the depot.
                if (self.alloc_from_depot(&self.empty_mags)) |empty_mag| {
                    // Put the Free magazine on the full list.
                    if (cpu.free) |full_mag| {
                        self.free_to_depot(full_mag, &self.full_mags);
                    }

                    cpu.free = empty_mag;
                    cpu.free_rounds = 0;
                    continue;
                }

                // No empty magazine in the depot, try to allocate a new one.
                cpu.lock.release_no_ipl();

                const new_mag: ?*Magazine = @ptrCast(@alignCast(self.magtype.?.zone.alloc() catch null));

                cpu.lock.acquire_no_ipl();

                if (new_mag) |m| {
                    self.free_to_depot(m, &self.empty_mags);
                    continue;
                }

                // Failed to allocate a magazine. Fall back to the slab layer.
                break;
            }
        }

        if (is_poison_enabled) {
            if (self.dtor) |dtor| {
                dtor(obj);
            }
            fill_with_poison(obj, self.obj_size, free_poison);
        }

        self.lock.acquire_no_ipl();
        defer self.lock.release_no_ipl();

        // Find the slab for the buffer.
        const slab: *Slab = if (self.obj_size > small_slab_size) blk: {
            const page_va = std.mem.alignBackward(usize, @intFromPtr(obj), mm.page_size);
            const phys = mi.kernel_space.pmap.query(page_va).?;
            const page = mm.pfn_to_struct_page(mm.page_to_pfn(phys));
            break :blk page.alloced.slab_data.slab;
        } else blk: {
            break :blk @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(obj), mm.page_size));
        };

        const was_full = slab.refcount == slab.capacity;
        const idx = (@intFromPtr(obj) - slab.base) / self.chunk_size;
        slab.bitmap_free(idx);
        slab.refcount -= 1;

        if (was_full) {
            // There were no buffers in the slab, so it wasn't in the freelist.
            // Now that there is a buffer, add it back to the freelist.
            slab.link.remove();
            self.partial_slabs.insert_head(&slab.link);
        }

        if (slab.refcount == 0) {
            // No more outstanding allocations, it is safe to reclaim the slab.
            slab.link.remove();
            self.slab_destroy(slab);
            return;
        }
    }

    fn alloc_page() !*anyopaque {
        const alloc_ret = mi.phys.alloc();
        return @ptrFromInt(mm.p2v(alloc_ret));
    }

    fn free_page(p: *anyopaque) void {
        const phys = mm.v2p(@intFromPtr(p));

        mi.phys.free(phys);
    }

    fn slab_create_small(self: *Self) mm.Error!*Slab {
        const buf = try alloc_page();

        // We employ a simple coloring scheme; every time a slab is created,
        // the color is shifted by the alignment. This is done until we reach the
        // max color (which is when there is no space left in the slab buffer).
        // This ensures uniform buffer address distribution.
        self.color += self.alignment;

        if (self.color > self.max_color) {
            self.color = 0;
        }

        const capacity = Slab.calc_capacity(self.chunk_size, self.color);

        // Slab info is located at the beginning of the page.
        var slab: *Slab = @ptrCast(@alignCast(buf));

        slab.refcount = 0;
        slab.capacity = @intCast(capacity);
        slab.base = @intFromPtr(slab) + @sizeOf(Slab) + Slab.bitmap_bytes(slab.capacity) + self.color;

        const bm = slab.bitmap();
        const full_words = capacity / 64;
        for (0..full_words) |i| bm[i] = std.math.maxInt(u64);
        const rem = capacity % 64;
        if (rem > 0) {
            bm[full_words] = (@as(u64, 1) << @intCast(rem)) - 1;
        }

        for (0..capacity) |i| {
            const obj: *anyopaque = @ptrFromInt(slab.base + i * self.chunk_size);
            if (is_poison_enabled) {
                fill_with_poison(obj, self.obj_size, free_poison);
            } else {
                if (self.ctor) |ctor| ctor(obj);
            }
        }

        return slab;
    }

    fn slab_create_large(self: *Self) mm.Error!*Slab {
        self.color += self.alignment;

        if (self.color > self.max_color) {
            self.color = 0;
        }

        const capacity = (self.slab_size - self.color) / self.chunk_size;
        const buf = try mi.heap.alloc(self.slab_size);

        var ret: *Slab = @ptrCast(@alignCast(try gpa.alloc(u8, @sizeOf(Slab) + Slab.bitmap_bytes(capacity))));

        // Mark the bitmap as all free
        const bm = ret.bitmap();
        const full_words = capacity / 64;

        for (0..full_words) |i| bm[i] = std.math.maxInt(u64);
        const rem = capacity % 64;
        if (rem > 0) bm[full_words] = (@as(u64, 1) << @intCast(rem)) - 1;

        ret.base = @intFromPtr(buf) + self.color;
        ret.buf = @intFromPtr(buf);
        ret.capacity = @intCast(capacity);
        ret.refcount = 0;

        for (0..self.slab_size / mm.page_size) |i| {
            const phys_page = mi.kernel_space.pmap.query(@intFromPtr(buf) + i * mm.page_size) orelse @panic("Could not query page");
            const page = mm.pfn_to_struct_page(mm.page_to_pfn(phys_page));
            page.alloced.slab_data.slab = ret;
        }

        for (0..capacity) |i| {
            const obj: *anyopaque = @ptrFromInt(ret.base + i * self.chunk_size);

            if (is_poison_enabled) {
                fill_with_poison(obj, self.obj_size, free_poison);
            } else {
                if (self.ctor) |ctor| ctor(obj);
            }
        }

        return ret;
    }

    fn slab_create(self: *Self) mm.Error!*Slab {
        if (self.obj_size <= small_slab_size) {
            return self.slab_create_small();
        } else {
            return self.slab_create_large();
        }
    }

    fn slab_destroy(self: *Self, slab: *Slab) void {
        if (!is_poison_enabled) {
            if (self.dtor) |dtor| {
                for (0..slab.capacity) |i| {
                    const obj: *anyopaque = @ptrFromInt(slab.base + i * self.chunk_size);
                    dtor(obj);
                }
            }
        }

        if (self.obj_size > small_slab_size) {
            const alloc_size = @sizeOf(Slab) + Slab.bitmap_bytes(slab.capacity);
            gpa.free(@as([*]u8, @ptrCast(slab))[0..alloc_size]);

            mm.heap.free(slab.buf, self.slab_size);
        } else {
            free_page(@ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(slab), mm.page_size)));
        }
    }

    fn maglist_alloc(list_head: *?*Magazine) ?*Magazine {
        const ret = list_head.* orelse return null;
        list_head.* = ret.next;

        return ret;
    }

    fn maglist_free(list_head: *?*Magazine, mag: *Magazine) void {
        mag.next = list_head.*;
        list_head.* = mag;
    }

    fn alloc_from_depot(self: *Self, maglist: *?*Magazine) ?*Magazine {
        self.depot_lock.acquire_no_ipl();
        const ret = maglist_alloc(maglist);
        self.depot_lock.release_no_ipl();
        return ret;
    }

    fn free_to_depot(self: *Self, mag: *Magazine, maglist: *?*Magazine) void {
        self.depot_lock.acquire_no_ipl();
        maglist_free(maglist, mag);
        self.depot_lock.release_no_ipl();
    }
};

/// Parameterized version of Zone, useful for object caches.
pub fn TypedZone(comptime T: type) type {
    return struct {
        zone: Zone,

        const Self = @This();

        pub const InitOptions = struct {
            ctor: ?*const fn (*T) void = null,
            dtor: ?*const fn (*T) void = null,
        };

        pub fn init(self: *@This(), name: []const u8, options: InitOptions) void {
            self.zone.init(name, @sizeOf(T), .{
                .alignment = @alignOf(T),
                .ctor = @ptrCast(options.ctor),
                .dtor = @ptrCast(options.dtor),
            });
        }

        pub fn create(self: *Self) mm.Error!*T {
            const ret = try self.zone.alloc();
            return @ptrCast(@alignCast(ret));
        }

        pub fn destroy(self: *Self, obj: *T) void {
            self.zone.free(obj);
        }
    };
}

pub fn early_init() linksection(r.init) void {
    for (0..generic_zones.len, &generic_zones) |i, *zone| {
        zone.init(generic_zone_names[i], @as(usize, 1) << @intCast(i + 3), .{});
    }

    for (&magtypes) |*mtype| {
        mtype.zone.init("magazine", @sizeOf(Magazine) + mtype.rounds * @sizeOf(*anyopaque), .{
            .alignment = mtype.alignment,
            .magazines = false,
        });
    }
}

/// Post-SMP initialization.
pub fn late_init() linksection(r.init) void {
    // Go through all caches with magazines enabled and initialize their per-CPU magazines.
    var zone = all_zones;

    while (zone) |z| {
        if (z.use_magazines) {
            z.cpus = gpa.alloc(Cpu, ke.ncpus) catch @panic("Failed to allocate per-CPU magazine state");

            for (0..ke.ncpus) |i| {
                z.cpus[i] = .{
                    .lock = .init(),
                    .alloc = null,
                    .free = null,
                    .alloc_rounds = 0,
                    .free_rounds = 0,
                    .magazine_size = z.magtype.?.rounds,
                };
            }
        }
        zone = z.next;
    }

    magazines_initialized = true;
}

// === Global general purpose allocator ===
pub const gpa: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = gpa_alloc,
        .resize = gpa_resize,
        .free = gpa_free,
        .remap = gpa_remap,
    },
};

fn gpa_alloc(
    ctx: *anyopaque,
    len: usize,
    ptr_align: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    _ = ctx;

    if (len > 2048) {
        if (ptr_align.toByteUnits() > mm.page_size) return null;
        const pages = std.mem.alignForward(usize, len, mm.page_size);
        const ptr = mi.heap.alloc(pages) catch return null;
        return @ptrCast(ptr);
    }

    const zone = zone_for(len, ptr_align.toByteUnits()) orelse return null;
    const obj = zone.alloc() catch return null;
    return @ptrCast(obj);
}

fn gpa_resize(
    _: *anyopaque,
    buf: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    if (buf.len > 2048) {
        // Allow shrinking within the same page-rounded allocation.
        const old_pages = std.mem.alignForward(usize, buf.len, mm.page_size);
        const new_pages = std.mem.alignForward(usize, new_len, mm.page_size);
        return new_pages <= old_pages;
    }
    // Can't resize in place. Only allow shrinking within the same zone.
    const old_zone = zone_for(buf.len, 1) orelse return false;
    const new_zone = zone_for(new_len, 1) orelse return false;
    return old_zone == new_zone;
}

fn gpa_remap(
    _: *anyopaque,
    buf: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    if (gpa_resize(undefined, buf, alignment, new_len, ret_addr)) return buf.ptr;

    const new_ptr = gpa_alloc(undefined, new_len, alignment, ret_addr) orelse return null;
    const copy_len = @min(buf.len, new_len);
    @memcpy(new_ptr[0..copy_len], buf[0..copy_len]);
    gpa_free(undefined, buf, alignment, ret_addr);
    return new_ptr;
}

fn gpa_free(
    _: *anyopaque,
    buf: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {
    if (buf.len > 2048) {
        const pages = std.mem.alignForward(usize, buf.len, mm.page_size);
        mm.heap.free(@intFromPtr(buf.ptr), pages);
        return;
    }

    const zone = zone_for(buf.len, 1) orelse return;
    zone.free(@ptrCast(buf.ptr));
}

fn zone_for(size: usize, alignment: usize) ?*Zone {
    const needed = @max(size, alignment);

    for (&generic_zones) |*zone| {
        if (zone.obj_size >= needed and zone.chunk_size % @max(alignment, 1) == 0) {
            return zone;
        }
    }

    return null;
}
