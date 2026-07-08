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
    /// Thread currently holding the object, and the target of any donation.
    owner: ?*ke.Thread,
    /// Linkage into `owner`'s `turnstiles_owned` list.
    boost_link: rtl.List.Entry,
    /// Priority currently donated to `owner`, null means this turnstile is not
    /// boosting anyone.
    donated: ?u8,
};

const Chain = struct {
    /// List of turnstiles on the chain.
    list: rtl.List,
    /// Lock for the chain.
    lock: ke.SpinLock,
};

/// Which queue to block or wakeup threads on.
pub const Queue = enum(u1) {
    /// Only one waiter will be woken up at once.
    Exclusive = 0,
    /// All waiters will be woken up.
    Shared = 1,
};

var chains: [num_chains]Chain = undefined;

fn hash_obj(obj: *const anyopaque) usize {
    return (@intFromPtr(obj) >> 6) & hash_mask;
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

/// Compute the inherited priority of `td` from the turnstiles it
/// owns. `td.lock` must be held.
fn recompute_inherited(td: *ke.Thread) void {
    var pri: u8 = 0;
    var it = td.turnstiles_owned.iterator();
    while (it.next()) : (it.advance()) {
        const ts: *Turnstile = @fieldParentPtr("boost_link", it.get());
        pri = @max(pri, ts.donated orelse 0);
    }
    td.inherited_prio = pri;
}

fn update_prio(td: *ke.Thread) void {
    const pri = td.effective_priority();
    if (pri != td.priority) ki.sched.update_priority_locked(td, pri);
}

/// Donate priority `pri` to `to` through turnstile `ts`. The caller holds
/// `to.lock` and `ts`'s chain lock. Returns whether `to`'s effective priority
/// actually rose (false means the chain stops here).
fn donate_to(ts: *Turnstile, to: *ke.Thread, pri: u8) bool {
    std.debug.assert(ts.owner == to);

    // A lend only ever raises.
    if (ts.donated != null and pri <= ts.donated.?) return false;

    const before = to.priority;

    if (ts.donated == null) to.turnstiles_owned.insert_head(&ts.boost_link);
    ts.donated = pri;
    if (pri > to.inherited_prio) to.inherited_prio = pri;

    update_prio(to);
    return to.priority > before;
}

/// Detach `ts`'s donation from whatever thread it is currently boosting and
/// recompute that thread's priority (which may lower it). Caller holds `ts`'s
/// chain lock.
fn revoke(ts: *Turnstile) void {
    // Not boosting anyone.
    if (ts.donated == null) return;

    const to = ts.owner.?;
    to.lock.acquire_no_ipl();
    ts.boost_link.remove();
    ts.donated = null;
    // Recompute the priority as the floor may drop now.
    recompute_inherited(to);
    update_prio(to);
    to.lock.release_no_ipl();
}

/// (Re)establish `ts`'s donation to `to` from its current set of waiters.
/// Caller holds `ts`'s chain lock.
fn reboost(ts: *Turnstile, to: *ke.Thread) void {
    const pri = highest_waiter(ts);
    if (pri == null) return;

    to.lock.acquire_no_ipl();
    _ = donate_to(ts, to, pri.?);
    to.lock.release_no_ipl();
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
        const bucket = &chains[hash_obj(obj)];

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
        const owner = ts.owner orelse break;
        if (owner == curtd) @panic("turnstile: cycle in blocking chain");

        owner.lock.acquire_no_ipl();
        if (!donate_to(ts, owner, donate)) {
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

/// Look up the turnstile for the specified object.
/// This acquires the turnstile chain lock and must be called at IPL dispatch.
/// Returns null if no turnstile is found.
pub fn lookup(obj: *const anyopaque) ?*Turnstile {
    const chain = &chains[hash_obj(obj)];

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
    chains[hash_obj(obj)].lock.release_no_ipl();
}

/// Block the current thread on a synchronization object backed by a turnstile.
/// This must be called with the appropriate turnstile chain lock held,
/// and returns with the chain lock released. IPL is kept as before on return.
pub fn block(turnstile: ?*Turnstile, obj: *anyopaque, owner: *ke.Thread, queue: Queue) void {
    const chain = &chains[hash_obj(obj)];
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

        if (turn.owner) |cur| {
            std.debug.assert(cur == owner);
        } else {
            // Owner might be null because of a partial wakeup
            // where we cleared it, restore it here.
            turn.owner = owner;
            reboost(turn, owner);
        }
    } else {
        // This is the first thread to block on this object.
        // Lend its turnstile and add it to the hash chain.
        ts = curtd.turnstile;
        ts.?.obj = obj;
        ts.?.owner = owner;
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
    _ = ke.wait.wait_one(&waiter.event.hdr, null) catch {
        _ = ke.ipl.raise(ipl);

        // If wait_one aborted (e.g. due to a timeout), remove the waiter and fix
        // up the owner's inheritance.
        chain.lock.acquire_no_ipl();

        if (curtd.turnstile_waiter == &waiter) {
            const active = ts.?;
            const holder = active.owner;
            revoke(active);
            dequeue(active, curtd);
            if (active.waiters > 0) {
                if (holder) |o| reboost(active, o);
            }
        }

        chain.lock.release_no_ipl();
        return;
    };
    _ = ke.ipl.raise(ipl);
}

/// Wake whomever was waiting on the turnstile.
/// Do hand-off to new_owner if specified.
pub fn wakeup(turnstile: *Turnstile, queue: Queue, count: usize, new_owner: ?*ke.Thread) void {
    const chain = &chains[hash_obj(turnstile.obj)];
    const queue_idx = @intFromEnum(queue);

    // The current owner is giving up the object, so it stops inheriting from
    // this turnstile entirely.
    revoke(turnstile);

    if (new_owner) |no| {
        // Hand the object to a specific waiter, the rest now boost it.
        dequeue(turnstile, no);
        if (turnstile.waiters > 0) {
            turnstile.owner = no;
            reboost(turnstile, no);
        }
    } else {
        for (0..count) |_| {
            if (turnstile.queues[queue_idx].is_empty()) break;
            const waiter: *Waiter = @fieldParentPtr("link", turnstile.queues[queue_idx].first());
            dequeue(turnstile, waiter.thread);
        }
        if (turnstile.waiters > 0) turnstile.owner = null;
    }

    chain.lock.release_no_ipl();
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
        ts.queues[0].init();
        ts.queues[1].init();
        ts.next_free = null;
        ts.owner = null;
        ts.donated = null;
    }

    td.turnstile_waiter = null;
    ts.waiters -= 1;

    td.lock.acquire_no_ipl();
    td.waiting_on = null;
    td.lock.release_no_ipl();

    waiter.event.signal();
}
