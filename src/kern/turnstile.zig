const ke = @import("root").ke;
const ki = ke.private;
const rtl = @import("rtl");
const std = @import("std");

const num_chains = 128;
const hash_mask = num_chains - 1;

pub const Waiter = struct {
    link: rtl.List.Entry,
    event: ke.Event,
    thread: *ke.Thread,
};

/// One donation edge into a thread's `turnstiles_owned` list.
pub const Boost = struct {
    /// Linkage into the boosted thread's `turnstiles_owned` list.
    link: rtl.List.Entry,
    /// Priority currently donated, null means this edge is not boosting anyone.
    donated: ?u8,
};

/// A thread a turnstile donates to, and the donation made on its behalf.
pub const Owner = struct {
    link: rtl.List.Entry,
    thread: *ke.Thread,
    boost: Boost,
};

pub const Ownership = union(enum) {
    /// Single owner.
    single: *ke.Thread,
    /// Multiple owners.
    shared: *rtl.List,
};

const OwnerSet = union(enum) {
    none,
    single: struct {
        thread: *ke.Thread,
        boost: Boost,
    },
    shared: *rtl.List,
};

/// One thread a turnstile donates to.
const Target = struct {
    thread: *ke.Thread,
    boost: *Boost,
};

pub const Turnstile = struct {
    /// Linkage for hash chain.
    link: rtl.List.Entry,
    /// Linkage on freelist.
    next_free: ?*Turnstile,
    /// Waiter queues, indexed by the queue type specified in `Queue`.
    queues: [2]rtl.List,
    /// Number of waiters on this turnstile.
    waiters: usize,
    /// Object threads are waiting on.
    obj: *anyopaque,
    /// Threads this turnstile donates to.
    owners: OwnerSet,

    fn detach(ts: *Turnstile) void {
        ts.owners = .none;
    }

    pub fn reset(ts: *Turnstile) void {
        ts.next_free = null;
        ts.queues[0].init();
        ts.queues[1].init();
        ts.detach();
    }
};

const Chain = struct {
    /// List of turnstiles on the chain.
    list: rtl.List,
    /// Lock for the chain.
    lock: ke.SpinLock,
};

/// Which queue to block or wakeup threads on.
pub const Queue = enum(u1) {
    Exclusive = 0,
    Shared = 1,
};

var chains: [num_chains]Chain = undefined;

fn hash_obj(obj: *const anyopaque) usize {
    return (@intFromPtr(obj) >> 6) & hash_mask;
}

fn chain_for(obj: *const anyopaque) *Chain {
    return &chains[hash_obj(obj)];
}

/// Highest effective priority among all waiters on `ts`, or 0 if none.
/// The caller must hold `ts`'s chain lock so the waiter set is stable.
fn highest_waiter(ts: *Turnstile) ?u8 {
    var best: ?u8 = null;
    for (&ts.queues) |*q| {
        var it = q.iterator();
        while (it.next()) : (it.advance()) {
            const w: *Waiter = @fieldParentPtr("link", it.get());
            w.thread.lock.acquire_no_ipl();
            best = @max(best orelse 0, w.thread.priority);
            w.thread.lock.release_no_ipl();
        }
    }
    return best;
}

/// Walks the threads a turnstile donates to, this is to abstract over the
/// different kinds of ownership.
const Targets = struct {
    single: ?Target,
    list: ?rtl.List.Iterator,

    fn next(self: *Targets) ?Target {
        if (self.single) |t| {
            self.single = null;
            return t;
        }

        if (self.list) |*it| {
            if (!it.next()) return null;
            const o: *Owner = @fieldParentPtr("link", it.get());
            it.advance();
            return .{ .thread = o.thread, .boost = &o.boost };
        }

        return null;
    }
};

fn targets(ts: *Turnstile) Targets {
    return switch (ts.owners) {
        .none => .{ .single = null, .list = null },
        .single => .{ .single = sole_owner(ts), .list = null },
        .shared => |list| .{ .single = null, .list = list.iterator() },
    };
}

/// The turnstile's owner when there is exactly one to follow, else null.
fn sole_owner(ts: *Turnstile) ?Target {
    return switch (ts.owners) {
        .single => .{
            .thread = ts.owners.single.thread,
            .boost = &ts.owners.single.boost,
        },
        else => null,
    };
}

/// Compute the inherited priority of `td` from the turnstiles it
/// owns. `td.lock` must be held.
fn recompute_inherited(td: *ke.Thread) void {
    var pri: u8 = 0;
    var it = td.turnstiles_owned.iterator();
    while (it.next()) : (it.advance()) {
        const boost: *Boost = @fieldParentPtr("link", it.get());
        pri = @max(pri, boost.donated orelse 0);
    }
    td.inherited_prio = pri;
}

fn update_prio(td: *ke.Thread) void {
    const pri = td.effective_priority();
    if (pri != td.priority) ki.sched.update_priority_locked(td, pri);
}

/// Donate priority `pri` to `to` along the edge `boost`. The caller holds
/// `to.lock` and the owning turnstile's chain lock. Returns whether `to`'s
/// priority actually rose (false means the chain stops here).
fn donate_to(boost: *Boost, to: *ke.Thread, pri: u8) bool {
    // A lend only ever raises.
    if (boost.donated != null and pri <= boost.donated.?) return false;

    const before = to.priority;

    if (boost.donated == null) to.turnstiles_owned.insert_head(&boost.link);
    boost.donated = pri;
    if (pri > to.inherited_prio) to.inherited_prio = pri;

    update_prio(to);
    return to.priority > before;
}

/// Undo the donation currently boosting `to`. The caller
/// holds the owning turnstile's chain lock.
fn undonate(boost: *Boost, to: *ke.Thread) void {
    if (boost.donated == null) return;

    to.lock.acquire_no_ipl();
    boost.link.remove();
    boost.donated = null;
    // Recompute the priority as the floor may drop now.
    recompute_inherited(to);
    update_prio(to);
    to.lock.release_no_ipl();
}

/// Detach `ts`'s donations from the threads they boost and recompute their
/// priorities. Caller holds `ts`'s chain lock.
fn revoke(ts: *Turnstile) void {
    var it = targets(ts);
    while (it.next()) |t| undonate(t.boost, t.thread);
}

/// (Re)establish `ts`'s donations from its current set of waiters.
/// Caller holds `ts`'s chain lock.
fn reboost(ts: *Turnstile) void {
    const pri = highest_waiter(ts) orelse return;
    var it = targets(ts);
    while (it.next()) |t| {
        t.thread.lock.acquire_no_ipl();
        _ = donate_to(t.boost, t.thread, pri);
        t.thread.lock.release_no_ipl();
    }
}

fn attach(ts: *Turnstile, own: Ownership) void {
    ts.owners = switch (own) {
        .single => |td| .{ .single = .{
            .thread = td,
            .boost = .{ .link = undefined, .donated = null },
        } },
        .shared => |list| .{ .shared = list },
    };
}

fn attached(ts: *Turnstile, own: Ownership) bool {
    return switch (own) {
        .single => |td| if (sole_owner(ts)) |t| t.thread == td else false,
        .shared => |list| switch (ts.owners) {
            .shared => |cur| cur == list,
            else => false,
        },
    };
}

/// Lend `curtd`'s effective priority down the blocking chain, boosting each
/// successive owner until one is already at least as high.
///
/// Locking:
///   - `root` is held by the caller on entry and is held again on return.
///   - If another chain bucket cannot be trylocked, we drop the current thread
///     lock and `root`, then reacquire `root` and restart from `curtd`.
///   - Any other chain bucket is taken with trylock. At most one such bucket is
///     held at a time.
fn propagate(curtd: *ke.Thread, root: *Chain) void {
    var donate = curtd.priority;
    var thread = curtd;
    var held: ?*Chain = null;

    while (true) {
        // We hold `thread.lock` (curtd's on the first
        // pass, the previous owner's after a hop) and `root`, `held` is null.
        const obj = thread.waiting_on orelse break;
        const bucket = chain_for(obj);

        if (bucket != root) {
            if (!bucket.lock.try_acquire_no_ipl()) {
                std.debug.assert(held == null);

                // Drop everything and try again. This avoids a livelock
                // between two PI walks holding different roots and trying to
                // acquire each other.
                thread.lock.release_no_ipl();
                root.lock.release_no_ipl();

                root.lock.acquire_no_ipl();
                curtd.lock.acquire_no_ipl();

                thread = curtd;
                donate = curtd.priority;
                continue;
            }
            held = bucket;
        }
        std.debug.assert(thread.waiting_on == obj);

        const ts = thread.turnstile;

        if (sole_owner(ts)) |o| {
            // For single-owner locks, do multi-hop priority inheritance.
            // Multi-hop means we handle the case where a boosted thread itself
            // is waiting on another resource.
            const owner = o.thread;
            if (owner == curtd) @panic("turnstile: cycle in blocking chain");

            owner.lock.acquire_no_ipl();
            if (!donate_to(o.boost, owner, donate)) {
                owner.lock.release_no_ipl();
                break;
            }

            // The next hop blocks owner, so lend the owner's priority
            // down the chain.
            donate = owner.priority;

            // Keep the owner locked, drop everything below it.
            thread.lock.release_no_ipl();
            if (held) |h| h.lock.release_no_ipl();
            held = null;
            thread = owner;
        } else {
            // Only do single-hop priority boosting for multiple owners.
            // This is fine as we only use this for SMR read sections,
            // and they are forbidden to explicitly block.
            var it = targets(ts);
            while (it.next()) |t| {
                if (t.thread == curtd) @panic("turnstile: cycle in blocking chain");
                t.thread.lock.acquire_no_ipl();
                _ = donate_to(t.boost, t.thread, donate);
                t.thread.lock.release_no_ipl();
            }
            break;
        }
    }

    // Leave the caller holding exactly curtd.lock and root.
    if (held) |h| h.lock.release_no_ipl();
    if (thread != curtd) {
        thread.lock.release_no_ipl();
        curtd.lock.acquire_no_ipl();
    }
}

pub fn init_turnstiles() void {
    for (&chains) |*chain| {
        chain.list.init();
        chain.lock = .init();
    }
}

/// Add an owner to a turnstile whose ownership is shared. The caller inserts
/// `o` into the shared list and holds the chain lock.
pub fn owner_enter(ts: *Turnstile, o: *Owner) void {
    const pri = highest_waiter(ts) orelse return;

    o.thread.lock.acquire_no_ipl();
    _ = donate_to(&o.boost, o.thread, pri);
    o.thread.lock.release_no_ipl();
}

/// Revoke one owner's donation. The caller removes `o` from the shared list
/// and holds the chain lock.
pub fn owner_leave(o: *Owner) void {
    undonate(&o.boost, o.thread);
}

/// Look up the turnstile for the specified object.
/// This acquires the turnstile chain lock and must be called at IPL dispatch.
/// Returns null if no turnstile is found.
pub fn lookup(obj: *const anyopaque) ?*Turnstile {
    const chain = chain_for(obj);

    chain.lock.acquire_no_ipl();

    var it = chain.list.iterator();
    while (it.next()) : (it.advance()) {
        const turnstile: *Turnstile = @fieldParentPtr("link", it.get());
        if (turnstile.obj == obj) {
            return turnstile;
        }
    }

    return null;
}

/// Drop the lock protecting the chain for obj.
pub fn exit(obj: *const anyopaque) void {
    chain_for(obj).lock.release_no_ipl();
}

/// Block the current thread on a synchronization object backed by a turnstile,
/// donating to the owner set described by `own`.
///
/// This must be called with the appropriate turnstile chain lock held, and
/// returns with the chain lock released.
/// IPL is kept as before on return.
pub fn block(turnstile: ?*Turnstile, obj: *anyopaque, own: Ownership, queue: Queue) void {
    const chain = chain_for(obj);
    const curtd = ki.sched.percpu.local().current_thread.?;
    const ipl = ke.ipl.current();

    var ts = turnstile;
    const queue_idx = @intFromEnum(queue);

    std.debug.assert(chain.lock.is_locked());

    if (ts) |turn| {
        // Another thread already donated its turnstile,
        // Put our turnstile on the freelist.
        curtd.turnstile.next_free = turn.next_free;
        turn.next_free = curtd.turnstile;
        curtd.turnstile = turn;

        if (!attached(turn, own)) {
            // Either a partial wakeup detached the turnstile or the object
            // changed ownership, move the donation over.
            revoke(turn);
            attach(turn, own);
            reboost(turn);
        }
    } else {
        // This is the first thread to block on this object.
        // Lend its turnstile and add it to the hash chain.
        ts = curtd.turnstile;
        ts.?.obj = obj;
        attach(ts.?, own);
        chain.list.insert_head(&ts.?.link);
    }

    // Initialize a waiter struct for this thread.
    var waiter: Waiter = .{
        .event = undefined,
        .link = undefined,
        .thread = curtd,
    };

    waiter.event.init(.Synchronization);

    curtd.turnstile_waiter = &waiter;

    ts.?.queues[queue_idx].insert_tail(&waiter.link);
    ts.?.waiters += 1;

    // Record what we block on (the object) and lend our priority down the
    // blocking chain.
    curtd.lock.acquire_no_ipl();
    curtd.waiting_on = obj;
    propagate(curtd, chain);
    chain.lock.release_no_ipl();
    curtd.lock.release_no_ipl();

    // Now block on the event.
    _ = ke.ipl.lower(.Passive);
    _ = ke.wait.wait_one(&waiter.event.hdr, null) catch unreachable;
    _ = ke.ipl.raise(ipl);
}

/// Wake whomever was waiting on the turnstile.
/// Do hand-off to new_owner if specified.
/// The chain lock is still held on return.
pub fn wakeup(ts: *Turnstile, queue: Queue, count: usize, new_owner: ?*ke.Thread) void {
    const queue_idx = @intFromEnum(queue);

    // Revoke any priority we gave to the owner(s).
    revoke(ts);

    if (new_owner) |no| {
        // Hand the object to a specific waiter, the rest now boost it.
        dequeue(ts, no);
        if (ts.waiters > 0) {
            attach(ts, .{ .single = no });
            reboost(ts);
        }
    } else {
        for (0..count) |_| {
            if (ts.queues[queue_idx].is_empty()) break;
            const waiter: *Waiter = @fieldParentPtr("link", ts.queues[queue_idx].first());
            dequeue(ts, waiter.thread);
        }
        if (ts.waiters > 0) ts.detach();
    }
}

/// Remove a single waiter from the turnstile and wake it. Caller holds the
/// chain lock.
fn dequeue(ts: *Turnstile, td: *ke.Thread) void {
    std.debug.assert(td.turnstile == ts);
    std.debug.assert(td.turnstile_waiter != null);
    std.debug.assert(!ts.queues[0].is_empty() or !ts.queues[1].is_empty());

    const waiter = td.turnstile_waiter.?;
    waiter.link.remove();

    if (ts.next_free) |free| {
        // Steal a turnstile from the freelist.
        td.turnstile = free;
        ts.next_free = free.next_free;
        free.next_free = null;
    } else {
        // Last waiter, pull the turnstile off the chain and keep it for ourselves.
        ts.link.remove();
        ts.reset();
    }

    td.turnstile_waiter = null;
    ts.waiters -= 1;

    td.lock.acquire_no_ipl();
    td.waiting_on = null;
    td.lock.release_no_ipl();

    waiter.event.signal();
}
