//! Lock ordering verifier.

const config = @import("config");
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;

const std = @import("std");
const assert = std.debug.assert;

/// One relation state for a matrix entry.
const Relation = struct {
    /// bitmap[L] is set iff L is reachable from this lock.
    bitmap: [num_classes / @bitSizeOf(usize)]usize = @splat(0),

    fn index_for(idx: usize) struct { usize, u6 } {
        return .{
            idx / @bitSizeOf(usize),
            @intCast(idx % @bitSizeOf(usize)),
        };
    }

    pub fn contains(self: Relation, idx: usize) bool {
        const word, const bit = index_for(idx);
        return (self.bitmap[word] & (@as(usize, 1) << bit)) != 0;
    }

    pub fn set(self: *Relation, idx: usize) void {
        const word, const bit = index_for(idx);
        self.bitmap[word] |= (@as(usize, 1) << bit);
    }

    pub fn merge(self: *Relation, other: Relation) void {
        for (0.., other.bitmap) |i, word| {
            self.bitmap[i] |= word;
        }
    }
};

/// A lock class, represents logically a single lock type, e.g thread lock.
pub const Class = struct {
    name: []const u8,

    /// Index into the relationship matrix.
    idx: u32,

    entry: rtl.bst.Node,
};

const LockInstance = struct {
    class: ?*const Class,
    lock: *anyopaque,
};

const held_locks_max = 5;

const HeldLocks = struct {
    next: ?*HeldLocks = null,
    locks: [held_locks_max]LockInstance = undefined,
    num: u8 = 0,
};

pub const LockData =
    if (config.warden) ?*Class else void;

pub const HolderData = if (config.warden) HeldLocks else struct {};

const num_classes = 128;
const num_buckets = 128;

const cpu_held_spinlocks = ke.CpuLocalType(HeldLocks, .{});

/// Matrix of reachability between classes
var reachable: [num_classes]Relation = @splat(.{});
var graph_lock: ke.SpinLock = undefined;

var classes: [num_classes]Class = @splat(undefined);
var class_buckets: [num_classes]rtl.AvlTreeType(nodes_cmp) = @splat(.init());
var started = false;
var num_active_classes: u32 = 0;

fn nodes_cmp(a: *const rtl.bst.Node, b: *const rtl.bst.Node) std.math.Order {
    const aclass: *const Class = @fieldParentPtr("entry", a);
    const bclass: *const Class = @fieldParentPtr("entry", b);

    return std.mem.order(u8, aclass.name, bclass.name);
}

/// Find a lock class by its name.
fn find_lock_class(name: []const u8) struct {
    ?*Class,
    ?*rtl.AvlTreeType(nodes_cmp),
} {
    if (name.len == 0) {
        // This lock shouldn't be checked.
        return .{ null, null };
    }

    const hash = std.hash.Murmur2_32.hash(name);
    const bucket = &class_buckets[hash & (num_classes - 1)];

    var search_for: Class = .{
        .entry = undefined,
        .idx = 0,
        .name = name,
    };

    const res = bucket.tree.search(&search_for.entry);

    const class_res: ?*Class = if (res) |n|
        @fieldParentPtr("entry", n)
    else
        null;

    return .{ class_res, bucket };
}

/// Find a lock class by its name or create it if it doesn't exist.
pub fn find_or_create_lock_class(name: []const u8) ?*Class {
    if (name.len == 0) {
        return null;
    }

    const ipl = graph_lock.acquire_at(.High);
    defer graph_lock.release(ipl);

    const found, const bucket = find_lock_class(name);

    if (found != null) {
        return found;
    }

    assert(num_active_classes < num_classes);

    // Get a new spot for our class.
    const class = &classes[num_active_classes];
    class.name = name;

    // Insert it so that we can find it by name.
    bucket.?.insert(&class.entry) catch {
        // This would only fail if the lock class already existed.
        // Since this was accounted for earlier, the error can never happen.
        unreachable;
    };

    num_active_classes += 1;

    return class;
}

/// Add an edge from parent to child.
fn add_edge(
    parent: *const Class,
    child: *const Class,
) error{LockOrderReversal}!void {
    if (reachable[child.idx].contains(parent.idx)) {
        @branchHint(.unlikely);
        return error.LockOrderReversal;
    }

    if (child.idx == parent.idx) {
        return;
    }

    if (reachable[parent.idx].contains(child.idx)) {
        // We already know about it!
        return;
    }

    var mask = reachable[child.idx];
    mask.set(child.idx);

    // Now try to match up transitive dependencies, i.e
    // A -> B -> C, if we already knew A -> B and now we want to link B->C,
    // make a direct link from A -> C.
    for (0..num_active_classes) |i| {
        // Find each ancestor of parent.
        if (!reachable[i].contains(parent.idx) and i != parent.idx)
            continue;

        // Merge all reachable nodes from C to A.
        reachable[i].merge(mask);
    }
}

/// Check that a lock of class `class` acquisition is safe.
fn check_impl(class: ?*const Class, held_locks: *HeldLocks) void {
    if (started == false) {
        return;
    }

    const c = class orelse return;
    const num = held_locks.num;

    if (num == 0) {
        // First lock, nothing to check.
        return;
    }

    var fast = true;

    // First try doing it lock-free as to avoid contention on the graph lock.
    // This is *technically* UB against the memory model, but don't bother
    // trying to use atomic reads when this is much nicer & simpler to do.
    for (0..held_locks.num) |i| {
        const held = held_locks.locks[i];
        const hc = held.class orelse continue;

        if (!reachable[hc.idx].contains(c.idx)) {
            fast = false;
        }
    }

    if (fast)
        return;

    // We couldn't determine that this is safe, so grab the lock and re-check.
    // Also add new edges if needed.
    const ipl = graph_lock.acquire_at(.High);

    for (0..held_locks.num) |i| {
        const held = held_locks.locks[i];
        const hc = held.class orelse continue;

        add_edge(hc, c) catch {
            graph_lock.release(ipl);

            std.debug.panic(
                "Lock ordering inversion at between {s} and {s}",
                .{
                    c.name,
                    hc.name,
                },
            );
        };
    }

    graph_lock.release(ipl);
}

/// Called when a lock got acquired.
fn acquired_impl(
    lock: *anyopaque,
    class: ?*const Class,
    held_locks: *HeldLocks,
) void {
    const num = held_locks.num;

    assert(num < held_locks_max);

    held_locks.locks[num].class = class;
    held_locks.locks[num].lock = lock;

    held_locks.num += 1;
}

/// Called when a lock gets released.
fn released_impl(
    lock: *anyopaque,
    held_locks: *HeldLocks,
) void {
    const num = held_locks.num;
    assert(num > 0);

    var i: u32 = 0;

    // Find the lock we just released.
    for (held_locks.locks[0..num]) |l| {
        if (l.lock == lock) break;
        i += 1;
    }

    assert(i < num);

    held_locks.num = num - 1;

    // Shift all other locks down.
    for (i..held_locks.num) |j| {
        held_locks.locks[j] = held_locks.locks[j + 1];
    }
}

const LockKind = enum {
    Spin,
    Lock,
};

/// Called when a spinlock gets acquired.
pub fn acquired(
    lock: *anyopaque,
    class: ?*const Class,
    comptime kind: LockKind,
) void {
    if (started == false) return;

    if (kind == .Spin) {
        const ipl = ke.ipl.raise(.High);
        const cpu = cpu_held_spinlocks.local();

        acquired_impl(lock, class, cpu);

        ke.ipl.lower(ipl);
    } else {
        const curtd = ke.thread.current();
        acquired_impl(lock, class, &curtd.warden_data);
    }
}

/// Called when a lock gets released.
pub fn released(lock: *anyopaque, comptime kind: LockKind) void {
    if (kind == .Spin) {
        const ipl = ke.ipl.raise(.High);
        const cpu = cpu_held_spinlocks.local();
        released_impl(lock, cpu);
        ke.ipl.lower(ipl);
    } else {
        const curtd = ke.thread.current();
        released_impl(lock, &curtd.warden_data);
    }
}

/// Check that a lock acquisition is safe.
pub fn check(class: ?*const Class, comptime kind: LockKind) void {
    if (class == null) return;

    if (kind == .Spin) {
        const ipl = ke.ipl.raise(.High);
        const cpu = cpu_held_spinlocks.local();

        check_impl(class, cpu);

        ke.ipl.lower(ipl);
    } else {
        const curtd = ke.thread.current();
        check_impl(class, &curtd.warden_data);
    }
}

/// Initialize the kernel warden.
pub fn init() void {
    graph_lock = ke.SpinLock.init("");

    for (0.., &classes) |i, *class| {
        class.idx = @truncate(i);
    }

    started = true;
}
