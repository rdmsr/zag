//! Slab allocator implementation with per-CPU object caching.
//! As described in Bonwick's "The Slab Allocator: An Object-Caching Kernel Memory Allocator"
//! and "Magazines and Vmem: Extending the Slab Allocator to Many CPUs and Arbitrary Resources".
const rtl = @import("rtl");
const b = @import("base");
const config = @import("config");
const std = @import("std");
const ke = b.ke;
const mm = b.mm;
const mi = mm.private;

// TODO: when SMP is setup, do proper magazine initialization.

/// A bufctl is a control structure for a single object in a slab.
/// It is used to track free objects and link them together in the slab's free list.
const BufCtl = struct {
    /// Next BufCtl in the list.
    next: ?*BufCtl,
    /// Pointer to the object this BufCtl manages.
    buffer: *anyopaque,
    /// Pointer to the owning Slab.
    slab: *Slab,
};

/// A slab is a contiguous memory region that holds multiple objects of the same type.
const Slab = struct {
    /// Linkage into a zone's list of slabs.
    link: rtl.List.Entry,
    /// Reference count indicating how many objects are in use.
    refcount: usize,
    /// Pointer to the first free BufCtl in this slab.
    buflist: ?*BufCtl,
    /// Base address of the slab.
    base: usize,
};

/// A magazine is a per-CPU cache of objects for a zone.
const Magazine = struct {
    /// Next magazine in the list.
    next: ?*Magazine,
    /// One or more rounds.
    rounds: [*]*anyopaque,
};

const MagazineType = struct {
    rounds: usize,
    alignment: usize,
    minbuf: usize,
    maxbuf: usize,
    /// Magazine zone.
    zone: *Zone,
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

/// This is an arbitrary number, ideally this should be determined on zone
/// creation based on the object size and slab size,
/// but for simplicity we just use a constant here.
const objects_per_slab = 16;

/// Zones used to allocate out-of-line bufctls for large slabs.
var bufctl_zone: TypedZone(BufCtl) = undefined;
var slab_zone: TypedZone(Slab) = undefined;

/// Generic zones for power-of-two sizes from 8 to 2048.
var generic_zones: [generic_zones_num]Zone = undefined;

var magazines_enabled = false;

const magtypes = [_]MagazineType{
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
const is_poison_enabled = @hasDecl(config, "CONFIG_SLAB_POISON");
const should_check_poison = @hasDecl(config, "CONFIG_SLAB_POISON_CHECK");

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
    lock: ke.SpinLock,
    /// List of full slabs in this zone.
    full_slabs: rtl.List,
    /// List of partial slabs in this zone.
    partial_slabs: rtl.List,
    /// Linkage into the global static zone free list.
    next: ?*Zone,
    /// Buffer-to-bufctl hash map.
    bufmap: [*]?*BufCtl,

    hash_mask: usize,
    hash_shift: usize,

    depot_lock: ke.SpinLock,

    empty_mags: ?*Magazine,
    full_mags: ?*Magazine,
    magtype: ?MagazineType,
    /// Per-CPU state.
    cpus: [*]Cpu,

    ctor: ?*const fn (obj: *anyopaque) void,
    dtor: ?*const fn (obj: *anyopaque) void,

    hash0: [initial_hash]?*BufCtl,

    const Self = @This();

    pub const InitOptions = struct {
        alignment: usize = 0,
        ctor: ?*const fn (*anyopaque) void = null,
        dtor: ?*const fn (*anyopaque) void = null,
    };

    /// Initialize a zone.
    pub fn init(self: *Self, name: []const u8, size: usize, options: InitOptions) void {
        const obj_align = if (options.alignment == 0) slab_align else options.alignment;
        var chunk_size = std.mem.alignForward(usize, size, obj_align);

        const offset, chunk_size = if (size <= small_slab_size) blk: {
            if (chunk_size - size >= @sizeOf(usize)) {
                // Use padding at end of chunk.
                break :blk .{ chunk_size - @sizeOf(usize), chunk_size };
            } else {
                // No space, extend the chunk.
                break :blk .{ chunk_size, chunk_size + slab_align };
            }
        } else blk: {
            // Out-of-line bufctl
            break :blk .{ 0, chunk_size };
        };

        const slab_size, const max_color = if (size <= small_slab_size) blk: {
            const ss = mm.page_size;
            break :blk .{ ss, @rem(ss - @sizeOf(Slab), chunk_size) };
        } else blk: {
            const ss = calc_slab_size(chunk_size);
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
        self.offset = offset;
        self.ctor = options.ctor;
        self.dtor = options.dtor;
        self.hash_mask = initial_hash - 1;
        self.hash_shift = std.math.log2_int_ceil(usize, chunk_size);
        self.lock = .init();
        self.bufmap = &self.hash0;

        self.magtype = null;
        for (&magtypes) |*mtype| {
            if (mtype.maxbuf >= chunk_size) {
                self.magtype = mtype.*;
                break;
            }
        }
    }

    /// Allocate an object from the zone.
    pub fn alloc(self: *Self) mm.Error!*anyopaque {
        const ipl = ke.ipl.raise(.Dispatch);
        defer ke.ipl.lower(ipl);
        var buf: *anyopaque = undefined;

        // Try grabbing an object from the magazine layer.
        if (magazines_enabled) {
            const cpu = &self.cpus[ke.cpu.current()];

            cpu.lock.acquire_no_ipl();
            defer cpu.lock.release_no_ipl();

            while (true) {
                if (cpu.alloc_rounds > 0) {
                    // Fast path: just pop from the alloc magazine.
                    cpu.alloc_rounds -= 1;
                    buf = cpu.alloc.?.rounds[cpu.alloc_rounds];

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

        var bufctl = slab.buflist orelse return error.OutOfMemory;

        if (bufctl.next == null) {
            slab.link.remove();
            self.full_slabs.insert_tail(&slab.link);
        }

        slab.buflist = bufctl.next;
        slab.refcount += 1;

        if (self.obj_size > small_slab_size) {
            const bucket = self.bufctl_from_obj(bufctl.buffer);

            buf = bufctl.buffer;
            bufctl.next = bucket.*;
            bucket.* = bufctl;
        } else {
            buf = @ptrFromInt(@intFromPtr(bufctl) - self.offset);
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

        if (magazines_enabled) {
            const cpu = &self.cpus[ke.cpu.current()];

            cpu.lock.acquire_no_ipl();
            defer cpu.lock.release_no_ipl();

            while (true) {
                if (cpu.free_rounds < cpu.magazine_size) {
                    // Fast path: push directly to free magazine.
                    if (is_poison_enabled) {
                        if (self.dtor) |dtor| {
                            dtor(obj);
                        }

                        fill_with_poison(obj, self.obj_size, free_poison);
                    }

                    cpu.free.?.rounds[cpu.free_rounds] = obj;
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
                    cpu.free = m;
                    cpu.free_rounds = 0;
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

        // Find the bufctl for the buffer.
        var bufctl: ?*BufCtl = null;
        var slab: ?*Slab = null;

        if (self.obj_size > small_slab_size) {
            // Search through the hash map and remove it.
            var prev = self.bufctl_from_obj(@ptrCast(obj));

            while (prev.* != null) {
                const bc = prev.*;

                if (@intFromPtr(bc.?.buffer) == @intFromPtr(obj)) {
                    prev.* = bc.?.next;
                    slab = bc.?.slab;
                    bufctl = bc.?;
                    break;
                }

                prev = &bc.?.next;
            }
        } else {
            bufctl = @ptrFromInt(@intFromPtr(obj) + self.offset);
            slab = @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(obj), mm.page_size) + mm.page_size - @sizeOf(Slab));
        }

        if (slab == null or bufctl == null) {
            return;
        }

        const s = slab.?;
        const bufc = bufctl.?;

        if (s.buflist == null) {
            // There were no buffers in the slab, so it wasn't in the freelist.
            // Now that there is a buffer, add it back to the freelist.
            s.link.remove();
            self.partial_slabs.insert_head(&s.link);
        }

        // Insert bufctl into the slab freelist.
        bufc.next = s.buflist;
        s.buflist = bufc;

        s.refcount -= 1;

        if (s.refcount == 0) {
            // No more outstanding allocations, it is safe to reclaim the slab.
            s.link.remove();
            self.slab_destroy(s);
            return;
        }
    }

    inline fn bufctl_from_obj(self: *Self, buffer: *anyopaque) *?*BufCtl {
        return &self.bufmap[(@intFromPtr(buffer) >> @intCast(self.hash_shift)) & self.hash_mask];
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
        var buf = try alloc_page();

        // We employ a simple coloring scheme; every time a slab is created,
        // the color is shifted by the alignment. This is done until we reach the
        // max color (which is when there is no space left in the slab buffer).
        // This ensures uniform buffer address distribution.
        self.color += self.alignment;

        if (self.color > self.max_color) {
            self.color = 0;
        }

        // Slab info is located at the end of the page.
        var slab: *Slab = @ptrFromInt(@intFromPtr(buf) + mm.page_size - @sizeOf(Slab));

        const capacity = (mm.page_size - @sizeOf(Slab) - self.color) / self.chunk_size;

        slab.buflist = null;
        slab.refcount = 0;
        slab.base = @intFromPtr(buf);

        buf = @ptrFromInt(@intFromPtr(buf) + self.color);

        for (0..capacity) |i| {
            var bufctl: *BufCtl = @ptrFromInt(@intFromPtr(buf) + (i * self.chunk_size) + self.offset);
            const obj: *anyopaque = @ptrFromInt(@intFromPtr(buf) + (i * self.chunk_size));

            // Add bufctl to the freelist
            // NOTE: a bufctl field other than next must not be modified.
            bufctl.next = slab.buflist;
            slab.buflist = bufctl;

            if (is_poison_enabled) {
                fill_with_poison(obj, self.obj_size, free_poison);
            } else {
                if (self.ctor) |ctor| ctor(obj);
            }
        }

        return slab;
    }

    fn slab_create_large(self: *Self) !*Slab {
        self.color += self.alignment;

        if (self.color > self.max_color) {
            self.color = 0;
        }

        const capacity = (self.slab_size - self.color) / self.chunk_size;
        const buf = try mi.heap.alloc_pages(self.slab_size);

        var ret: *Slab = try slab_zone.create();

        ret.buflist = null;
        ret.base = @intFromPtr(buf);

        for (0..capacity) |i| {
            var bufctl: *BufCtl = try bufctl_zone.create();

            bufctl.buffer = @ptrFromInt(@intFromPtr(buf) + self.color + i * self.chunk_size);
            bufctl.slab = ret;

            bufctl.next = ret.buflist;
            ret.buflist = bufctl;

            if (is_poison_enabled) {
                fill_with_poison(bufctl.buffer, self.obj_size, free_poison);
            } else {
                if (self.ctor) |ctor| ctor(bufctl.buffer);
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
                var bufctl = slab.buflist;
                while (bufctl) |bc| : (bufctl = bc.next) {
                    const obj = if (self.obj_size > small_slab_size)
                        bc.buffer
                    else
                        @as(*anyopaque, @ptrFromInt(@intFromPtr(bc) - self.offset));
                    dtor(obj);
                }
            }
        }

        if (self.obj_size > small_slab_size) {
            var bufctl = slab.buflist;

            while (bufctl != null) {
                const next = bufctl.?.next;
                bufctl_zone.destroy(bufctl.?);
                bufctl = next;
            }

            slab_zone.destroy(slab);

            // FIXME: call free_pages on slab.base here!
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

    fn calc_slab_size(chunk_size: usize) usize {
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

pub fn early_init() linksection(b.init) void {
    bufctl_zone.init("bufctl", .{});
    slab_zone.init("slab", .{});

    for (0..generic_zones.len, &generic_zones) |i, *zone| {
        zone.init(generic_zone_names[i], @as(usize, 1) << @intCast(i + 3), .{});
    }
}
