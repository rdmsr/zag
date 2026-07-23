//! Slab allocator implementation with per-CPU object caching.
//! Roughly based on XNU's zone allocator, which itself is based on FreeBSD's
//! UMA. First described in Jeff Bonwick's "The Slab Allocator: An
//! Object-Caching Kernel Memory Allocator" and "Magazines and Vmem: Extending
//! the Slab Allocator to Many CPUs and Arbitrary Resources", both from Solaris.
//!
//! ## Structure
//! ------------
//! The allocator is split in three layers:
//! 1. Per-CPU layer
//! 2. Zone depot layer
//! 3. Slab layer
//! Both (1) and (2) rely on so-called "magazines", an array of (constructed)
//! objects that is either loaded in the CPU or sits in a *depot*, a collection
//! of magazines. Each depot maintains full and empty magazine lists used to
//! satisfy magazine allocation requests.
//!
//! ## Per-CPU layer
//! ----------------
//! Each CPU has an `alloc` and `free` magazine, where objects are allocated
//! from and freed to, respectively. This separation avoids hysteresis and is useful
//! for safe memory reclamation (see below).
//! When one side runs dry/full, the magazines may be swapped, if SMR is disabled.
//! Each CPU also has its own depot, from which it allocates and frees its
//! magazines to first. If there is no magazine in the local depot, the magazine
//! will be provided from the zone depot layer. We keep track of the size of the
//! depot and grow or shrink it according to configured limits (by default
//! 128 KiB of memory is allowed to be kept around for each CPU) and using a
//! weighted moving average (WMA) based on the contention on the zone depot's
//! lock; if contention is determined to be too high, the CPU's depot is grown
//! as to avoid falling back onto the zone depot too much.
//!
//! ## Zone depot layer
//! -------------------
//! The zone depot layer serves as a fallback when no magazines are available in
//! the per-CPU depot, its size is managed through a working-set size algorithm
//! that uses the WMA of the minimum required magazines in an update window.
//! Moving between the zone depot layer and the per-CPU layer is done in batches
//! as to avoid overly holding the zone depot lock and satisfy the desired
//! per-CPU depot size.
//!
//! ## Slab layer
//! -------------
//! The slab layer is the fallback when all previous layers failed. A slab
//! represents a contiguous chunk of memory holding a fixed number of constructed
//! objects, determined when the zone is created, and is allocated via the
//! kernel's virtual memory allocator. Allocation in the slab is managed by a
//! bitmap and slab metadata is retrieved through the `mm.Page` structure
//! representing the page of allocated memory.
//!
//! ## Hardening features
//! ---------------------
//! Some basic hardening features are implemented in the allocator. Firstly,
//! all allocations are done in a FIFO manner as to annoy attackers which might
//! try exploiting double-free or use-after-free bugs (which shouldn't happen
//! since I never write bugs :^)).
//! For example, consider this use-after-free sequence in a LIFO allocator:
//! 1. Dangling pointer to A (oops!)
//! 2. free A
//! 3. alloc B
//! 4. The dangling pointer to A and B now point to the same address.
//!
//! For a double free scenario, an exploit would look like this:
//! 1. free A
//! 2. alloc B -> B points to the last freed address (A)
//! 3. free A (oops!)
//! 4. alloc C -> C points to the last freed address (A)
//! 5. Both C and B now point to the same address.
//!
//! Doing things in a FIFO way makes things less predictable but might incur
//! performance degradation as older elements may be colder in cache),so this
//! policy can be disabled changing a Zone's reuse policy on creation.
//! Additionally, heap poisoning can be enabled via a compile-time zonfig
//! option, `slab_poison` will only poison objects (potentially detecting the
//! use of uninitialized memory), and `slab_check_poison` will actively enforce
//! that the poison data is still intact inside an object, detecting
//! use-after-free bugs.
//!
//! ## SMR zones
//! ------------
//! A zone may be tied to a SMR domain, in which case freed objects may not
//! be reused until a given sequence has been observed by all CPUs. The magazine
//! layer is used to amortize and batch this operation; instead of tracking a
//! per-object sequence, whole magazines are stamped.
//!
//! When the free magazine becomes full, it is stamped with a *deferred* advance
//! of the domain's write sequence, this advance is only committed once the
//! magazine actually reaches the zone depot. This is meant to pace commits with
//! regards to the per-CPU depot size, where a larger size will lead to less
//! commits. When alloc needs a full magazine, it first polls the sequence of
//! the head of the depot magazine list (since SMR zones are forced
//! FIFO and stamps are taken in monotonic order, the head always carries the
//! minimum sequence). If the local head has not expired, the local full magazines
//! are moved and appended to the zone depot to age, and their sequences
//! are committed, while expired magazines from the zone depot are pulled back in
//! to satisfy the request.
//!
//! All this machinery is to avoid expensive scans during SMR polling,
//! growing the per-CPU depots widens the window between a stamp and its poll
//! until the fast path (which is a single load) is all that runs.
//!
//! ## Extra notes
//! --------------
//! With poisoning enabled, constructors run when an object is allocated and
//! destructors run when it is freed. Without poisoning, constructors run when
//! an object leaves the slab layer and destructors run when it returns to it,
//! slabs hold raw objects while magazines hold constructed ones.

const rtl = @import("rtl");
const r = @import("root");
const std = @import("std");
const config = @import("config");

const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const mi = mm.private;

/// Interval at which we do housekeeping (working set update, reaping, etc.)
const update_interval_s = 15;
const update_interval = std.time.ns_per_s * update_interval_s;
var update_work_item: ex.WorkItem = undefined;

/// Fixed point conversion for WMA computation.
const wma_unit = 256;

/// Default slab alignment.
const slab_align = 8;

/// Global count of zones.
const zones_num = 32;

/// Number of rounds in a magazine.
const magazine_size = ke.Tunable(u8, 8, "mm.zone.mag_size");

/// How much extra memory CPUs are allowed to keep around.
const max_local_memory = ke.Tunable(u32, r.kib(128), "mm.zone.max_local_mem");

/// Number of contentions allowed per second before the depot grows.
const depot_grow_level = ke.Tunable(u32, 5 * wma_unit, "mm.zone.depot_grow_level");

/// Number of contentions allowed per second before the depot shrinks.
const depot_shrink_level = ke.Tunable(u32, wma_unit / 2, "mm.zone.depot_shrink_level");

/// Number of excess magazines in a zone before they are trimmed.
const excess_magazines = ke.Tunable(u32, 8, "mm.zone.excess_mags");

/// Excess memory in a zone before magazines are trimmed.
const excess_memory = ke.Tunable(u32, r.kib(16), "mm.zone.excess_mem");

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
var zone_list_lock: ke.Mutex = .init();

var magazine_zone: Zone = undefined;
var cpu_zone: Zone = undefined;

var smr_zone: TypedZone(ke.smr.Domain) = undefined;
var smr_cpu_zone: Zone = undefined;

const alloc_poison: u32 = 0xBADDC0DE;
const free_poison: u32 = 0xDEADBEEF;
const is_poison_enabled = config.slab_poison;
const should_check_poison = config.slab_check_poison;

/// A slab is a contiguous memory region that holds multiple objects of the same type.
const Slab = struct {
    /// Linkage into a zone's list of slabs.
    link: rtl.List.Entry,
    /// Reference count indicating how many objects are in use.
    refcount: u16,
    capacity: u16,
    /// Base address of the slab.
    base: usize,

    /// Round-robin cursor that is used to allocate objects from.
    /// This is used to avoid predictable heap behavior; an attacker
    /// will have more trouble exploiting double-free and use-after-free
    /// bugs (as if anyone would try exploiting this :p).
    alloc_rr: u16,

    pub fn bitmap(self: *Slab) [*]u64 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Slab));
    }

    pub fn bitmap_bytes(capacity: usize) usize {
        return std.mem.alignForward(usize, capacity, 64) / 8;
    }

    /// Allocates a free bit from the bitmap, returns the allocated bit.
    pub fn bitmap_alloc(self: *Slab) ?u16 {
        const bitmaps = std.mem.alignForward(usize, self.capacity, 64) / 64;
        const start_word = self.alloc_rr / 64;
        const start_bit = self.alloc_rr % 64;
        const low_mask: u64 = (@as(u64, 1) << @intCast(start_bit)) - 1;

        for (0..bitmaps) |i| {
            const word_idx = (start_word + i) % bitmaps;
            var chunk = self.bitmap()[word_idx];
            // Skip the bits behind the cursor on the first word we check.
            if (i == 0) chunk &= ~low_mask;
            if (chunk == 0) continue;

            return self.take_bit(word_idx, @ctz(chunk));
        }

        // Wrap around, check the bits behind the cursor that we skipped.
        const chunk = self.bitmap()[start_word] & low_mask;
        if (chunk != 0) return self.take_bit(start_word, @ctz(chunk));

        return null;
    }

    fn take_bit(self: *Slab, word_idx: usize, bit: anytype) u16 {
        self.bitmap()[word_idx] &= ~(@as(u64, 1) << @intCast(bit));
        const allocated: u16 = @intCast(word_idx * 64 + bit);
        self.alloc_rr = if (allocated + 1 >= self.capacity) 0 else allocated + 1;
        return allocated;
    }

    /// Free a bit to the bitmap.
    pub fn bitmap_free(self: *Slab, idx: usize) void {
        const bm = self.bitmap();

        const bit = @as(u64, 1) << @intCast(idx % 64);
        std.debug.assert(bm[idx / 64] & (bit) == 0);

        bm[idx / 64] |= bit;
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
    pub fn calc_capacity(chunk_size: usize, alignment: usize) usize {
        // Start with the largest possible capacity.
        var capacity = (mm.page_size - @sizeOf(Slab)) / chunk_size;

        // Shrink capacity until both the objects and the bitmap fit.
        // Each iteration we recalculate the bitmap size for the new capacity,
        // since a smaller capacity means a smaller bitmap, which may then fit.
        while (capacity > 0) : (capacity -= 1) {
            const objects_off =
                std.mem.alignForward(usize, @sizeOf(Slab) + Slab.bitmap_bytes(capacity), alignment);

            if (objects_off + capacity * chunk_size <= mm.page_size) {
                break;
            }
        }

        return capacity;
    }
};

/// A magazine is a per-CPU cache of objects for a zone.
const Magazine = struct {
    /// Next magazine in the list.
    next: ?*Magazine,
    /// Stamped sequence if the zone is SMR.
    seq: ke.smr.Sequence,
    /// Rounds follow in memory after the struct.
    pub fn rounds_ptr(self: *Magazine) [*]*anyopaque {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Magazine));
    }
};

const MagazineList = struct {
    /// List of magazines.
    head: ?*Magazine,
    tail: ?*Magazine,
    /// Number of magazines.
    num: usize,
    /// Minimum since last update
    min: usize,
    /// Weighted moving average of `min`, scaled by `wma_unit`.
    wma: usize,
};

const ReusePolicy = enum {
    LIFO,
    FIFO,
};

const Depot = struct {
    empty_mags: MagazineList,
    full_mags: MagazineList,

    fn maglist_alloc(list: *MagazineList) ?*Magazine {
        const ret = list.head orelse return null;
        list.head = ret.next;
        if (list.head == null) list.tail = null;
        ret.next = null;
        return ret;
    }

    fn maglist_free(list: *MagazineList, mag: *Magazine, policy: ReusePolicy) void {
        mag.next = null;

        if (policy == .FIFO) {
            if (list.tail) |tail| {
                tail.next = mag;
            } else {
                list.head = mag;
            }

            list.tail = mag;
        } else {
            mag.next = list.head;
            list.head = mag;
            if (list.tail == null) list.tail = mag;
        }
    }

    fn alloc(maglist: *MagazineList) ?*Magazine {
        const ret = maglist_alloc(maglist);
        if (ret != null) {
            maglist.num -= 1;
            maglist.min = @min(maglist.min, maglist.num);
        }
        return ret;
    }

    fn free(mag: *Magazine, maglist: *MagazineList, policy: ReusePolicy) void {
        maglist_free(maglist, mag, policy);
        maglist.num += 1;
    }
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
    /// Local per-CPU depot.
    depot: Depot,
};

pub const Page = extern struct {
    slab: *Slab,
};

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

inline fn wma_mix(old: usize, new: usize) usize {
    // Keep 75% of old sample and 25% of new.
    return (3 * old + new * wma_unit) / 4;
}

fn cpus_alloc() []rtl.CachePadded(Cpu) {
    const ptr = cpu_zone.alloc(.{}) catch @panic("failed to allocate zone CPU state");
    const raw: [*]rtl.CachePadded(Cpu) = @ptrCast(@alignCast(ptr));
    return raw[0..ke.ncpus];
}

pub const Zone = struct {
    /// Name used for debugging purposes.
    name: []const u8,
    /// Size of objects in this zone.
    obj_size: usize,
    /// Alignment of objects in this zone.
    alignment: u16,
    /// Size of a slab.
    slab_size: usize,
    /// Size of a chunk.
    chunk_size: usize,
    /// Zone lock.
    lock: ke.Mutex,
    /// List of full slabs in this zone.
    full_slabs: rtl.List,
    /// List of partial slabs in this zone.
    partial_slabs: rtl.List,
    /// Linkage into the global zone list.
    next: ?*Zone,
    depot_lock: ke.QSpinLock,
    depot: Depot,
    /// Current contention rate, in contentions/second scaled by `wma_unit`.
    depot_contention_wma: usize,
    depot_contention_cur: usize,
    /// Size of the per-CPU depot.
    cpu_depot_size: usize,
    /// Maximum size of the per-CPU depot.
    cpu_depot_limit: usize,
    trim_depot: bool,

    /// Per-CPU state.
    cpus: []rtl.CachePadded(Cpu),

    ctor: ?*const fn (obj: *anyopaque) void,
    dtor: ?*const fn (obj: *anyopaque) void,

    use_magazines: bool,

    reuse_policy: ReusePolicy,

    smr: ?*ke.smr.Domain,

    const Self = @This();

    const InitOptions = struct {
        alignment: u16 = 0,
        ctor: ?*const fn (*anyopaque) void = null,
        dtor: ?*const fn (*anyopaque) void = null,
        magazines: bool = true,
        reuse_policy: ReusePolicy = .FIFO,
        smr: ?*ke.smr.Domain = null,
    };

    /// Initialize a zone.
    pub fn init(self: *Self, name: []const u8, size: usize, options: InitOptions) void {
        const obj_align = if (options.alignment == 0) slab_align else options.alignment;
        const chunk_size = std.mem.alignForward(usize, size, obj_align);

        const slab_size = if (size <= small_slab_size) mm.page_size else Slab.calc_slab_size(chunk_size);

        self.full_slabs.init();
        self.partial_slabs.init();

        self.name = name;
        self.obj_size = size;
        self.alignment = obj_align;
        self.slab_size = slab_size;
        self.chunk_size = chunk_size;
        self.ctor = options.ctor;
        self.dtor = options.dtor;
        self.lock = .init();
        self.use_magazines = options.magazines;

        self.depot = std.mem.zeroes(Depot);
        self.depot_contention_cur = 0;
        self.depot_contention_wma = 0;
        self.cpu_depot_size = 0;
        self.cpu_depot_limit = max_local_memory.load() / (self.chunk_size * magazine_size.load());
        self.trim_depot = false;

        // SMR zones have to be FIFO so that the minimum sequence can be
        // obtained by checking the list head.
        self.reuse_policy = if (options.smr != null) .FIFO else options.reuse_policy;
        self.smr = options.smr;

        zone_list_lock.acquire();

        const prev = all_zones;
        all_zones = self;
        self.next = prev;

        zone_list_lock.release();

        if (!magazines_initialized) {
            return;
        }

        self.cpus = cpus_alloc();

        for (0..ke.ncpus) |i| {
            self.cpus[i].value.lock = .init();
            self.cpus[i].value.alloc = null;
            self.cpus[i].value.free = null;
            self.cpus[i].value.alloc_rounds = 0;
            self.cpus[i].value.free_rounds = 0;
            self.cpus[i].value.depot = std.mem.zeroes(Depot);
        }
    }

    /// Allocate an object from the zone.
    pub fn alloc(self: *Self, opts: struct { policy: mm.WaitPolicy = .WaitForMemory }) mm.Error!*anyopaque {
        var buf: *anyopaque = undefined;

        // Try grabbing an object from the magazine layer.
        if (magazines_initialized and self.use_magazines) {
            @branchHint(.likely);

            const ipl = ke.ipl.raise(.Dispatch);
            var cpu = &self.cpus[ke.cpu.current()].value;
            cpu.lock.acquire_no_ipl();
            defer cpu.lock.release(ipl);

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

                if (cpu.free_rounds > 0 and self.smr == null) {
                    std.debug.assert(cpu.free != null);

                    // Alloc magazine is empty. If the free magazine has items, swap them.
                    // The free magazine now becomes our alloc magazine.
                    std.mem.swap(?*Magazine, &cpu.alloc, &cpu.free);
                    std.mem.swap(usize, &cpu.alloc_rounds, &cpu.free_rounds);
                    continue;
                }

                // Both magazines are empty.
                // Try to get a full magazine from the CPU-local depot.
                if (self.full_mags_ready(&cpu.depot.full_mags)) {
                    const full_mag = Depot.alloc(&cpu.depot.full_mags).?;

                    // Discard our empty alloc magazine to the depot.
                    if (cpu.alloc) |empty_mag| {
                        Depot.free(empty_mag, &cpu.depot.empty_mags, self.reuse_policy);
                    }

                    self.magazine_reuse(full_mag);
                    cpu.alloc = full_mag;
                    cpu.alloc_rounds = magazine_size.load();
                    continue;
                }

                // Local depot is empty, rebalance with the zone depot.
                // Purposefully race against cpu_depot_size because locking is tricky here,
                // we may get a stale value but it is harmless.
                const n = @atomicLoad(usize, &self.cpu_depot_size, .monotonic);

                self.alloc_depot_rebalance(n, cpu);

                // Try getting a full magazine from the CPU-local depot again.
                if (self.full_mags_ready(&cpu.depot.full_mags)) {
                    const full_mag = Depot.alloc(&cpu.depot.full_mags).?;

                    // Discard our empty alloc magazine to the depot.
                    if (cpu.alloc) |empty_mag| {
                        Depot.free(empty_mag, &cpu.depot.empty_mags, self.reuse_policy);
                    }

                    self.magazine_reuse(full_mag);
                    cpu.alloc = full_mag;
                    cpu.alloc_rounds = magazine_size.load();
                    continue;
                }

                // Zone depot has no full magazines, fall back to the slab layer...
                break;
            }
        }

        // Fall back to the slab layer.
        self.lock.acquire();

        var slab: *Slab = undefined;

        if (self.partial_slabs.is_empty()) {
            self.lock.release();

            slab = try self.slab_create(opts.policy);

            self.lock.acquire();

            // Note: this is racy and could lead to two threads creating a slab at the same time.
            // Worst case scenario, we have one slab too many, so we don't care; we already did the work required
            // for slab construction and this ideally should not happen very often.
            self.partial_slabs.insert_tail(&slab.link);
        } else {
            slab = @fieldParentPtr("link", self.partial_slabs.first());
        }

        const idx = slab.bitmap_alloc() orelse {
            self.lock.release();
            return error.OutOfMemory;
        };

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
        }

        if (self.ctor) |ctor| {
            ctor(buf);
        }

        self.lock.release();
        return buf;
    }

    /// Free an object back to the zone.
    pub fn free(self: *Self, obj: *anyopaque) void {
        if (magazines_initialized and self.use_magazines) {
            @branchHint(.likely);

            var ipl = ke.ipl.raise(.Dispatch);
            var cpu = &self.cpus[ke.cpu.current()].value;

            cpu.lock.acquire_no_ipl();
            const freed = while (true) {
                if (cpu.free != null and cpu.free_rounds < magazine_size.load()) {
                    // Fast path: push directly to free magazine.
                    // For SMR zones the dtor and poisoning are deferred until
                    // the magazine is reused, readers may still hold the object.
                    if (is_poison_enabled and self.smr == null) {
                        if (self.dtor) |dtor| {
                            dtor(obj);
                        }

                        fill_with_poison(obj, self.obj_size, free_poison);
                    }

                    cpu.free.?.rounds_ptr()[cpu.free_rounds] = obj;
                    cpu.free_rounds += 1;

                    if (self.smr != null and cpu.free_rounds == magazine_size.load()) {
                        // Stamp the now-full magazine.
                        cpu.free.?.seq = ke.smr.deferred_advance(self.smr.?);
                    }

                    break true;
                }

                if (cpu.alloc_rounds == 0 and cpu.alloc != null and self.smr == null) {
                    // Free magazine is full. If the alloc magazine is completely empty, swap them.
                    // The empty alloc magazine becomes our new free magazine.
                    std.mem.swap(?*Magazine, &cpu.alloc, &cpu.free);
                    std.mem.swap(usize, &cpu.alloc_rounds, &cpu.free_rounds);
                    continue;
                }

                // Free magazine is full, and alloc magazine has items.
                // Try to get an empty magazine from the CPU-local depot.
                if (Depot.alloc(&cpu.depot.empty_mags)) |empty_mag| {
                    // Put the free magazine on the full list.
                    if (cpu.free) |full_mag| {
                        Depot.free(full_mag, &cpu.depot.full_mags, self.reuse_policy);
                    }

                    cpu.free = empty_mag;
                    cpu.free_rounds = 0;
                    continue;
                }

                // Local depot is empty, rebalance with the zone depot.
                // Race explained in alloc.
                const n = @atomicLoad(usize, &self.cpu_depot_size, .monotonic);

                self.free_depot_rebalance(n, cpu);

                // Try to get an empty magazine from the CPU-local depot again.
                if (Depot.alloc(&cpu.depot.empty_mags)) |empty_mag| {
                    // Put the free magazine on the full list.
                    if (cpu.free) |full_mag| {
                        Depot.free(full_mag, &cpu.depot.full_mags, self.reuse_policy);
                    }

                    cpu.free = empty_mag;
                    cpu.free_rounds = 0;
                    continue;
                }

                // No empty magazine in the depot, try to allocate a new one.
                // We need to drop IPL and the CPU lock here because we need to acquire
                // the magazine's allocator's blocking lock.
                cpu.lock.release(ipl);
                const new_mag: ?*Magazine = @ptrCast(@alignCast(magazine_zone.alloc(.{ .policy = .DontWaitForMemory }) catch null));

                // Re-grab our current context.
                ipl = ke.ipl.raise(.Dispatch);
                cpu = &self.cpus[ke.cpu.current()].value;
                cpu.lock.acquire_no_ipl();

                if (new_mag) |m| {
                    m.seq = ke.smr.seq_invalid;

                    // Got one, try again.
                    Depot.free(m, &cpu.depot.empty_mags, self.reuse_policy);
                    continue;
                }

                // Failed to allocate a magazine. Fall back to the slab layer.
                break false;
            };

            cpu.lock.release(ipl);
            if (freed) return;
        }

        if (self.smr) |smr| {
            // Direct frees must synchronize, the object is instantly reusable.
            _ = ke.smr.poll(smr, ke.smr.advance(smr), true);
        }

        self.lock.acquire();
        self.slab_free(obj, true);
        self.lock.release();
    }

    fn slab_free(self: *Self, obj: *anyopaque, poison: bool) void {
        if (!is_poison_enabled or poison) {
            if (self.dtor) |dtor| {
                dtor(obj);
            }
        }

        if (is_poison_enabled and poison) {
            fill_with_poison(obj, self.obj_size, free_poison);
        }

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
            self.partial_slabs.insert_tail(&slab.link);
        }

        if (slab.refcount == 0) {
            // No more outstanding allocations, it is safe to reclaim the slab.
            slab.link.remove();
            self.slab_destroy(slab);
            return;
        }
    }

    /// Periodic updates on the zone.
    /// Updates the working set and trims it if needed (for now, will do magazine resizing later...).
    fn update(self: *Self) void {
        const ipl = self.depot_lock.acquire();

        // Update the working set size.
        // This tracks the minimum number of magazines required, we assume it is safe
        // to reclaim `min` magazines, since the number of magazines never went below that, and
        // those magazines sat unused. e.g if the number of magazines ranged between 47 and 37 in an update
        // interval, then the working set size is 10 and we can reclaim 37 magazines. We keep track of
        // this in a weighted moving average (WMA) to bias recent utilization when trimming.
        self.depot.empty_mags.wma = wma_mix(self.depot.empty_mags.wma, self.depot.empty_mags.min);
        self.depot.empty_mags.min = self.depot.empty_mags.num;

        self.depot.full_mags.wma = wma_mix(self.depot.full_mags.wma, self.depot.full_mags.min);
        self.depot.full_mags.min = self.depot.full_mags.num;

        // Calculate the number of contentions/second in fixed-point.
        const old = self.depot_contention_wma;
        var cur = self.depot_contention_cur * wma_unit / (ke.ncpus * update_interval_s);

        // WMA formula.
        cur = (3 * old + cur) / 4;

        if (self.use_magazines) {
            if (self.cpu_depot_size < self.cpu_depot_limit and cur > depot_grow_level.load()) {
                // We have room to grow the depot and we should.
                // Put the new WMA at around midpoint between shrink and growth, so that
                // we have time to check whether what we just did is good or not.
                cur = (depot_grow_level.load() + depot_shrink_level.load()) / 2;

                const size = if (self.cpu_depot_size == 0)
                    2
                else
                    // Grow by 1.5x.
                    (3 * self.cpu_depot_size) / 2;

                // Clamp it.
                self.cpu_depot_size = @min(size, self.cpu_depot_limit);
            } else if (self.cpu_depot_size > 0 and cur <= depot_shrink_level.load()) {
                // We should shrink the depot.
                cur = (depot_grow_level.load() + depot_shrink_level.load()) / 2;
                self.cpu_depot_size -= 1;
                self.trim_depot = true;
            }
        }

        self.depot_contention_cur = 0;
        self.depot_contention_wma = cur;

        const trim_depot = self.trim_depot;
        const should_trim = self.trim_needed();

        self.trim_depot = false;

        self.depot_lock.release(ipl);

        if (should_trim) {
            self.trim(trim_depot);
        }
    }

    /// Returns whether or not we should trim excess magazines.
    fn trim_needed(self: *Self) bool {
        if (!self.use_magazines) return false;
        if (self.trim_depot) return true;

        const empty = @min(self.depot.empty_mags.wma, self.depot.empty_mags.min * wma_unit);

        if (empty > excess_magazines.load() * wma_unit) {
            // Too many excess magazines.
            return true;
        }

        const full = @min(self.depot.full_mags.wma, self.depot.full_mags.min * wma_unit);

        const full_bytes = full * magazine_size.load() * self.chunk_size;

        if (full >= 2 * wma_unit and full_bytes >= excess_memory.load() * wma_unit) {
            // We have at least 2 excess full magazines and they take up at least 16 KiB.
            return true;
        }

        return false;
    }

    /// Called periodically to trim our magazines.
    /// This frees the excess magazines.
    fn trim(self: *Self, trim_depot: bool) void {
        // Note: we do all of this under the zone lock,
        // but it *should* be a fairly quick operation, even though it is O(ncpus).
        self.lock.acquire();

        self.trim_maglist(&self.depot.empty_mags, 0);
        self.trim_maglist(&self.depot.full_mags, magazine_size.load());

        if (trim_depot) {
            // The depot has size changed, trim the CPU depots.
            var depot = std.mem.zeroes(Depot);

            for (0..ke.ncpus) |i| {
                self.trim_cpu(&self.cpus[i].value, &depot, self.cpu_depot_size);
            }

            self.maglist_destroy(depot.empty_mags.head, 0);
            self.maglist_destroy(depot.full_mags.head, magazine_size.load());
        }

        self.lock.release();
    }

    /// Called when memory is low and we need to make memory ASAP.
    /// Drains all magazines from the depot.
    fn drain(self: *Self) void {
        if (!self.use_magazines) return;

        // Note: we do all of this under the zone lock,
        // but it *should* be a fairly quick operation, even though it is O(ncpus).
        self.lock.acquire();

        const ipl = self.depot_lock.acquire();

        // Take all elements from the zone depot.
        var depot = self.depot;
        self.depot = std.mem.zeroes(Depot);

        self.depot_lock.release(ipl);

        // Trim all CPU depots to 0.
        for (0..ke.ncpus) |i| {
            self.trim_cpu(&self.cpus[i].value, &depot, 0);
        }

        self.maglist_destroy(depot.empty_mags.head, 0);
        self.maglist_destroy(depot.full_mags.head, magazine_size.load());

        self.lock.release();
    }

    fn trim_maglist(self: *Self, maglist: *MagazineList, rounds: usize) void {
        const ipl = self.depot_lock.acquire();

        // Grab the magazines and WSS under the depot lock.
        const target = @min(
            maglist.min * wma_unit,
            maglist.wma,
        ) / wma_unit;

        var removed_head: ?*Magazine = maglist.head;
        var last_removed: ?*Magazine = null;
        var removed: usize = 0;

        for (0..target) |_| {
            if (maglist.head) |head| {
                last_removed = head;
                maglist.head = head.next;
                removed += 1;
            } else break;
        }

        if (maglist.head == null) {
            maglist.tail = null;
        }

        if (last_removed) |last| {
            last.next = null;
        } else {
            removed_head = null;
        }

        maglist.min -= removed;
        maglist.num -= removed;
        maglist.wma -= removed * wma_unit;

        self.depot_lock.release(ipl);

        // Destroy each magazine.
        self.maglist_destroy(removed_head, rounds);
    }

    /// Trim a CPU's depot to `target`.
    fn trim_cpu(self: *Self, cpu: *Cpu, depot: *Depot, target: usize) void {
        const ipl = cpu.lock.acquire();

        // Split the target (cpu_depot_size) in 2 for each magazine type.
        // Bias towards full magazines because they are usually more useful
        // for us than empty magazines.
        const full_target = (target + 1) / 2;
        const empty_target = target / 2;

        if (cpu.depot.full_mags.num > full_target) {
            // Trim the excess full magazines.
            const n = cpu.depot.full_mags.num - full_target;

            // Move them to our depot.
            for (0..n) |_| {
                Depot.free(Depot.alloc(&cpu.depot.full_mags).?, &depot.full_mags, self.reuse_policy);
            }
        }

        if (cpu.depot.empty_mags.num > empty_target) {
            // Trim the excess empty magazines.
            const n = cpu.depot.empty_mags.num - empty_target;

            // Move them to our depot.
            for (0..n) |_| {
                Depot.free(Depot.alloc(&cpu.depot.empty_mags).?, &depot.empty_mags, self.reuse_policy);
            }
        }

        cpu.lock.release(ipl);
    }

    fn maglist_destroy(self: *Self, head: ?*Magazine, n: usize) void {
        var elems = head;
        while (elems) |mag| {
            elems = mag.next;
            self.magazine_destroy(mag, n);
        }
    }

    /// Destroy a magazine.
    fn magazine_destroy(self: *Self, magazine: *Magazine, rounds: usize) void {
        if (rounds != 0) {
            if (self.smr) |smr| {
                // The stamp may still be uncommitted if the magazine never
                // reached the zone depot.
                ke.smr.deferred_advance_commit(smr, magazine.seq);

                // Wait until we can destroy the magazine.
                _ = ke.smr.poll(smr, magazine.seq, true);
            }
        }

        // Free its rounds to the slab layer.
        // For SMR zones the free-time work was deferred, do it now.
        for (0..rounds) |i| {
            self.slab_free(magazine.rounds_ptr()[i], self.smr != null);
        }

        // Free the magazine.
        magazine_zone.free(magazine);
    }

    fn alloc_page(policy: mm.WaitPolicy) !*anyopaque {
        const alloc_ret = mi.phys.alloc_opts(.{ .policy = policy }) orelse return error.OutOfMemory;
        return @ptrFromInt(mm.p2v(alloc_ret));
    }

    fn free_page(p: *anyopaque) void {
        const phys = mm.v2p(@intFromPtr(p));

        mi.phys.free(phys);
    }

    fn slab_create_small(self: *Self, policy: mm.WaitPolicy) mm.Error!*Slab {
        const buf = try alloc_page(policy);

        const capacity = Slab.calc_capacity(self.chunk_size, self.alignment);

        // Slab info is located at the beginning of the page.
        var slab: *Slab = @ptrCast(@alignCast(buf));

        slab.alloc_rr = 0;
        slab.refcount = 0;
        slab.capacity = @intCast(capacity);
        const meta_end = @intFromPtr(slab) + @sizeOf(Slab) + Slab.bitmap_bytes(capacity);
        slab.base = std.mem.alignForward(usize, meta_end, self.alignment);

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
            }
        }

        return slab;
    }

    fn slab_create_large(self: *Self, policy: mm.WaitPolicy) mm.Error!*Slab {
        const capacity = (self.slab_size) / self.chunk_size;
        const buf = try mi.heap.alloc(self.slab_size, policy);

        var ret: *Slab = @ptrCast(@alignCast(try gpa.alloc(u8, @sizeOf(Slab) + Slab.bitmap_bytes(capacity))));

        // Mark the bitmap as all free.
        const bm = ret.bitmap();
        const full_words = capacity / 64;

        for (0..full_words) |i| bm[i] = std.math.maxInt(u64);
        const rem = capacity % 64;
        if (rem > 0) bm[full_words] = (@as(u64, 1) << @intCast(rem)) - 1;

        ret.link = undefined;
        ret.base = @intFromPtr(buf);
        ret.capacity = @intCast(capacity);
        ret.refcount = 0;
        ret.alloc_rr = 0;

        for (0..self.slab_size / mm.page_size) |i| {
            const phys_page = mi.kernel_space.pmap.query(@intFromPtr(buf) + i * mm.page_size) orelse @panic("Could not query page");
            const page = mm.pfn_to_struct_page(mm.page_to_pfn(phys_page));
            page.alloced.slab_data.slab = ret;
        }

        for (0..capacity) |i| {
            const obj: *anyopaque = @ptrFromInt(ret.base + i * self.chunk_size);

            if (is_poison_enabled) {
                fill_with_poison(obj, self.obj_size, free_poison);
            }
        }

        return ret;
    }

    fn slab_create(self: *Self, policy: mm.WaitPolicy) mm.Error!*Slab {
        if (self.obj_size <= small_slab_size) {
            return self.slab_create_small(policy);
        } else {
            return self.slab_create_large(policy);
        }
    }

    fn slab_destroy(self: *Self, slab: *Slab) void {
        if (self.obj_size > small_slab_size) {
            const alloc_size = @sizeOf(Slab) + Slab.bitmap_bytes(slab.capacity);
            gpa.free(@as([*]u8, @ptrCast(slab))[0..alloc_size]);

            mm.heap.free(slab.base, self.slab_size);
        } else {
            free_page(@ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(slab), mm.page_size)));
        }
    }

    /// Check that a full magazine can be taken from the list head.
    fn full_mags_ready(self: *Self, list: *MagazineList) bool {
        const head = list.head orelse return false;
        const smr = self.smr orelse return true;

        return ke.smr.poll(smr, head.seq, false);
    }

    /// Deferred free-time work for SMR zones, ran when a full magazine
    /// is reused after its grace period expired.
    fn magazine_reuse(self: *Self, mag: *Magazine) void {
        if (!is_poison_enabled or self.smr == null) return;

        for (0..magazine_size.load()) |i| {
            const obj = mag.rounds_ptr()[i];

            if (self.dtor) |dtor| {
                dtor(obj);
            }

            fill_with_poison(obj, self.obj_size, free_poison);
        }
    }

    /// Move all local full magazines to the zone depot so their sequences
    /// can age, committing their deferred advances. Depot lock is held.
    fn smr_rotate_full(self: *Self, smr: *ke.smr.Domain, cpu: *Cpu) void {
        const src = &cpu.depot.full_mags;
        const dst = &self.depot.full_mags;
        const tail = src.tail orelse return;

        // Splice the whole list onto the zone depot.
        if (dst.tail) |t| {
            t.next = src.head;
        } else {
            dst.head = src.head;
        }

        dst.tail = tail;
        dst.num += src.num;

        src.head = null;
        src.tail = null;
        src.num = 0;
        src.min = 0;

        // The last magazine has the newest stamp, committing it covers them all.
        ke.smr.deferred_advance_commit(smr, tail.seq);
    }

    /// Try to rebalance the zone and cpu depots w.r.t to each other after an allocation.
    /// The CPU depot moves its extra empty magazines to the zone depot, and tries
    /// to get full magazines from the zone depot up to `target`. CPU lock is held.
    fn alloc_depot_rebalance(self: *Self, target: usize, cpu: *Cpu) void {
        if (!self.depot_lock.try_acquire_no_ipl()) {
            // Register the contention.
            self.depot_lock.acquire_no_ipl();
            self.depot_contention_cur += 1;
        }

        if (cpu.depot.empty_mags.num >= target) {
            // We have excess empty magazines, move them to the zone depot.
            const n = cpu.depot.empty_mags.num - target / 2;

            for (0..n) |_| {
                Depot.free(Depot.alloc(&cpu.depot.empty_mags).?, &self.depot.empty_mags, self.reuse_policy);
            }
        }

        if (self.smr) |smr| {
            // We got here because the local head hasn't expired or there is
            // no local magazine at all, rotate the local magazines through the
            // zone depot to let their sequences age.
            // We then hope that the head of the zone depot has expired, otherwise we just return
            // and fall back to the slab layer.
            self.smr_rotate_full(smr, cpu);
        }

        // Grab a batch of full magazines from the zone depot.
        // Exchange at least one magazine even when the depot size is 0.
        const n = @min(@max(target, 1) - cpu.depot.empty_mags.num, self.depot.full_mags.num);

        if (n != 0 and self.full_mags_ready(&self.depot.full_mags)) {
            for (0..n) |_| {
                Depot.free(Depot.alloc(&self.depot.full_mags).?, &cpu.depot.full_mags, self.reuse_policy);
            }
        }

        self.depot_lock.release_no_ipl();
    }

    /// Try to rebalance the zone and cpu depots w.r.t to each other after a free.
    /// The CPU depot moves its extra full magazines to the zone depot, and tries
    /// to get empty magazines from the zone depot up to `target`. CPU lock is held.
    fn free_depot_rebalance(self: *Self, target: usize, cpu: *Cpu) void {
        if (!self.depot_lock.try_acquire_no_ipl()) {
            // Register the contention.
            self.depot_lock.acquire_no_ipl();
            self.depot_contention_cur += 1;
        }

        if (cpu.depot.full_mags.num >= target) {
            if (self.smr) |smr| {
                // Rotate all full magazines through the zone depot so their
                // sequences age, then try pulling back expired ones.
                self.smr_rotate_full(smr, cpu);

                const n = @min(target / 2, self.depot.full_mags.num);

                if (n != 0 and self.full_mags_ready(&self.depot.full_mags)) {
                    for (0..n) |_| {
                        Depot.free(Depot.alloc(&self.depot.full_mags).?, &cpu.depot.full_mags, self.reuse_policy);
                    }
                }
            } else {
                // We have excess full magazines, move them to the zone depot.
                const n = cpu.depot.full_mags.num - target / 2;

                for (0..n) |_| {
                    Depot.free(Depot.alloc(&cpu.depot.full_mags).?, &self.depot.full_mags, self.reuse_policy);
                }
            }
        }

        // Grab a batch of empty magazines from the zone depot.
        // Exchange at least one magazine even when the depot size is 0.
        const n = @min(@max(target, 1) - cpu.depot.full_mags.num, self.depot.empty_mags.num);
        for (0..n) |_| {
            Depot.free(Depot.alloc(&self.depot.empty_mags).?, &cpu.depot.empty_mags, self.reuse_policy);
        }

        self.depot_lock.release_no_ipl();
    }
};

/// Called periodically to do housekeeping tasks on zones.
fn update(_: ?*anyopaque) void {
    zone_list_lock.acquire();

    var zone = all_zones;

    while (zone) |z| : (zone = z.next) {
        z.update();
    }

    zone_list_lock.release();

    // Do it again.
    ex.work.enqueue_in(&update_work_item, update_interval);
}

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
            const ret = try self.zone.alloc(.{});
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

    magazine_zone.init("magazine", @sizeOf(Magazine) + magazine_size.load() * @sizeOf(*anyopaque), .{
        .magazines = false,
    });
}

/// Post-SMP initialization.
pub fn late_init() linksection(r.init) void {
    cpu_zone.init("cpus", @sizeOf(rtl.CachePadded(Cpu)) * ke.ncpus, .{
        .magazines = false,
        .alignment = std.atomic.cache_line,
    });

    // Go through all caches with magazines enabled and initialize their per-CPU magazines.
    zone_list_lock.acquire();
    var zone = all_zones;

    while (zone) |z| {
        if (z.use_magazines) {
            z.cpus = cpus_alloc();

            for (0..ke.ncpus) |i| {
                z.cpus[i] = .init(.{
                    .lock = .init(),
                    .alloc = null,
                    .free = null,
                    .alloc_rounds = 0,
                    .free_rounds = 0,
                    .depot = std.mem.zeroes(Depot),
                });
            }
        }
        zone = z.next;
    }

    zone_list_lock.release();

    magazines_initialized = true;
    update_work_item.init(.Normal, update, null);
    ex.work.enqueue_in(&update_work_item, update_interval);

    smr_zone.init("SMR", .{});
    smr_cpu_zone.init("SMR CPU", @sizeOf(ke.smr.Cpu) * ke.ncpus, .{});
}

pub fn smr_domain_create(preempt: bool) !*ke.smr.Domain {
    var dom: *ke.smr.Domain = try smr_zone.create();
    dom.cpus = @ptrCast(@alignCast(try smr_cpu_zone.alloc(.{})));
    dom.init(preempt);

    return dom;
}

pub fn drain() void {
    zone_list_lock.acquire();
    var zone = all_zones;

    while (zone) |z| : (zone = z.next) {
        z.drain();
    }

    zone_list_lock.release();
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
        const ptr = mi.heap.alloc(pages, .WaitForMemory) catch return null;
        return @ptrCast(ptr);
    }

    const zone = zone_for(len) orelse return null;
    const obj = zone.alloc(.{}) catch return null;
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
    const old_zone = zone_for(buf.len) orelse return false;
    const new_zone = zone_for(new_len) orelse return false;
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

    const zone = zone_for(buf.len) orelse return;
    zone.free(@ptrCast(buf.ptr));
}

fn zone_for(size: usize) ?*Zone {
    for (&generic_zones) |*zone| {
        if (zone.obj_size >= size) {
            return zone;
        }
    }

    return null;
}
