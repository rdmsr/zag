//! # Turnstiles
//! --------------
//! Turnstiles are a mechanism that originated in Solaris
//! that tracks a contended lock's state and its associated priority inheritance
//! state.
//!
//! ## Basic mechanism
//! ------------------
//! The basic idea is that there is one turnstile allocated per thread
//! - in case it may ever contend on a lock - and when a it contends on a lock,
//! its turnstile is inserted into global hash table (indexed by the hash of the
//! lock's address). When another thread goes to contend on that lock, it looks
//! up the hash table to see whether or not a turnstile was already registered,
//! in that case, it'll *donate* its turnstile to a free list. When the waiter
//! threads are woken up, they all steal a turnstile from the free list (a
//! turnstile does not stay associated with a thread for its entire lifetime).
//!
//! ## Priority inheritance
//! -----------------------
//! Priority inheritance is done to avoid *priority inversion*, a case where a
//! high-priority thread is blocked waiting for a low-priority thread to release
//! a lock, which might get preempted by another medium-priority thread.
//!
//! Priority inheritance is achieved through turnstiles by walking a
//! given turnstile's owner chain and willing the priority of the highest priority
//! waiter, i.e it will go through turnstile.owner.turnstile.owner...
//! until the end of the chain, inheriting the waiter's priority along the way.
//!
//! ## Locking
//! ----------
//! There is one spinlock per turnstile hash chain and one per turnstile,
//! which should hopefully be fine-grained enough such that there are no
//! scalability issues.
//!
//! When doing priority inheritance, things get a bit tricky because we need to
//! hold multiple turnstile locks at once (the original turnstile's lock, and
//! each subsequent turnstile we visit in the owner chain), to avoid deadlocks,
//! subsequent locks are trylocked. Each thread lock is also held and released
//! subsequently, as to avoid a thread changing its state under us without us
//! knowing about it.
//!
//! ## Resources
//! ------------
//! See the original Illumos implementation, the Solaris book or FreeBSD book for
//! a more in-depth description.
//! I have also written more about turnstiles here:
//! https://rdmsr.github.io/writing/turnstiles/.

const ke = @import("root").ke;
const kep = ke.private;
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

/// Turnstile structure.
/// ts: turnstile lock
/// b: bucket lock
pub const Turnstile = struct {
    /// Linkage for hash chain (b).
    link: rtl.List.Entry,
    /// Linkage on freelist (b).
    next_free: ?*Turnstile,
    /// Waiter queues, indexed by the queue type specified in `Queue` (ts).
    queues: [2]rtl.List,
    /// Number of waiters on this turnstile (ts).
    waiters: usize,
    /// Object threads are waiting on.
    obj: *anyopaque,
    /// Threads this turnstile donates to (ts).
    owners: OwnerSet,
    /// Lock protecting the turnstile's state.
    lock: ke.SpinLock,

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

/// Walks the threads a turnstile donates to.
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

/// The turnstile's owner when there is only one.
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
    if (pri != td.priority) kep.sched.update_priority_locked(td, pri);
}

/// Donate priority `pri` to `to` along the edge `boost`. The caller holds
/// `to.lock` and the owning turnstile's lock.
fn donate_to(boost: *Boost, to: *ke.Thread, pri: u8) void {
    // A lend only ever raises.
    if (boost.donated != null and pri <= boost.donated.?) return;

    if (boost.donated == null) to.turnstiles_owned.insert_head(&boost.link);
    boost.donated = pri;
    if (pri > to.inherited_prio) to.inherited_prio = pri;

    update_prio(to);
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
        donate_to(t.boost, t.thread, pri);
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
/// successive owner. `curtd.lock` and `curtd.turnstile.lock` are both held on
/// entry and released on return.
///
/// Go through every turnstile in the chain and acquire and release it
/// successively while still holding the original turnstile. Trylock since there
/// is no defined ordering between individual turnstiles.
fn propagate(curtd: *ke.Thread) void {
    var thread = curtd;
    var root: ?*Turnstile = curtd.turnstile;

    while (true) {
        // We hold `thread.lock` and `root.lock`.
        const obj = thread.waiting_on orelse break;

        std.debug.assert(thread.waiting_on == obj);

        const ts = thread.turnstile;

        // Try to acquire the next turnstile's lock if we don't already hold it.
        if (root == null or ts != root.?) {
            // Need to trylock here because there's an inversion;
            // the wakeup code wants turnstile -> thread ordering,
            // but we currently have a thread -> turnstile ordering.
            // We also need to do this to protect against concurrent PI walks
            // on the same turnstile.
            if (!ts.lock.try_acquire_no_ipl()) {
                // The turnstile could not be acquired, drop everything and
                // restart the walk from the start. Priority inheritance is idem-
                // potent so there is no issue in applying it many times.
                thread.lock.release_no_ipl();

                if (root) |ro| ro.lock.release_no_ipl();

                root = null;

                curtd.lock.acquire_no_ipl();
                thread = curtd;
                continue;
            }

            if (root == null) root = ts;
        }

        const donate = thread.priority;

        if (sole_owner(ts)) |o| {
            // For single-owner locks, hop onto the next owner.
            const owner = o.thread;

            if (owner == curtd) @panic("turnstile: cycle in blocking chain");

            owner.lock.acquire_no_ipl();
            donate_to(o.boost, owner, donate);

            thread.lock.release_no_ipl();

            if (ts != root.?)
                ts.lock.release_no_ipl();

            thread = owner;
        } else {
            // Only do single-hop priority boosting for multiple owners.
            // This is fine as we only use this for SMR read sections,
            // and they are forbidden to explicitly block.
            var it = targets(ts);
            while (it.next()) |t| {
                if (t.thread == curtd)
                    @panic("turnstile: cycle in blocking chain");
                t.thread.lock.acquire_no_ipl();
                donate_to(t.boost, t.thread, donate);
                t.thread.lock.release_no_ipl();
            }
            if (ts != root.?)
                ts.lock.release_no_ipl();
            break;
        }
    }

    thread.lock.release_no_ipl();
    if (root) |ro| ro.lock.release_no_ipl();
}

pub fn init_turnstiles() void {
    for (&chains) |*chain| {
        chain.list.init();
        chain.lock = ke.SpinLock.init("turnstile_chain");
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
/// and holds the appropriate locks.
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
            turnstile.lock.acquire_no_ipl();
            return turnstile;
        }
    }

    return null;
}

/// Drop the locks held by a corresponding `lookup`.
pub fn exit(obj: *const anyopaque, turnstile: ?*Turnstile) void {
    if (turnstile) |ts| {
        ts.lock.release_no_ipl();
    }

    chain_for(obj).lock.release_no_ipl();
}

/// Block the current thread on a synchronization object backed by a turnstile,
/// donating to the owner set described by `own`.
///
/// This must be called with the appropriate turnstile chain lock held, and
/// returns with the chain lock released.
/// IPL is kept as before on return.
pub fn block(
    turnstile: ?*Turnstile,
    obj: *anyopaque,
    own: Ownership,
    queue: Queue,
) void {
    const chain = chain_for(obj);
    const curtd = kep.sched.percpu.local().current_thread.?;
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

        ts.?.lock.acquire_no_ipl();
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
    chain.lock.release_no_ipl();
    curtd.lock.acquire_no_ipl();
    curtd.waiting_on = obj;
    propagate(curtd);

    // Now block on the event.
    _ = ke.ipl.lower(.Passive);
    _ = ke.wait.wait_one(&waiter.event.hdr, "turnstile:waiter", .{}) catch
        unreachable;
    _ = ke.ipl.raise(ipl);
}

/// Signal the end of a turnstile-backed wait and return a list of waiters to wake.
/// Do hand-off to new_owner if specified.
/// The locks acquired by `lookup` are still held on return.
pub fn signal(
    ts: *Turnstile,
    queue: Queue,
    count: usize,
    new_owner: ?*ke.Thread,
    waiters: *rtl.List,
) void {
    const queue_idx = @intFromEnum(queue);

    // Revoke any priority we gave to the owner(s).
    revoke(ts);

    waiters.init();

    if (new_owner) |no| {
        // Hand the object to a specific waiter, the rest now boost it.
        const w = dequeue(ts, no);
        waiters.insert_head(&w.link);

        if (ts.waiters > 0) {
            attach(ts, .{ .single = no });
            reboost(ts);
        }
    } else {
        for (0..count) |_| {
            if (ts.queues[queue_idx].is_empty()) break;
            const waiter: *Waiter = @fieldParentPtr(
                "link",
                ts.queues[queue_idx].first(),
            );
            const w = dequeue(ts, waiter.thread);

            waiters.insert_tail(&w.link);
        }
        if (ts.waiters > 0) ts.detach();
    }
}

/// Wake all waiters returned by `prepare_wakeup`, must be done after `exit`
/// is called.
pub fn wakeup(waiters: *rtl.List) void {
    // Now wake all the waiters, this ensures that the turnstile and chain lock
    // hold times stay low.
    // Also, if we did this *before* unlocking `ts`, there is no guarantee that it
    // is still alive, as the last waiter could've woken up, exited, and freed it.
    // Instead of special casing it, let's just do the wakeup in a nicer
    // environment here.
    var it = waiters.iterator();

    while (it.next()) : (it.advance()) {
        const waiter: *Waiter = @fieldParentPtr("link", it.current);
        waiter.event.signal();
    }
}

/// Remove a single waiter from the turnstile and return it.
fn dequeue(ts: *Turnstile, td: *ke.Thread) *Waiter {
    td.lock.acquire_no_ipl();

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
        // Last waiter, pull the turnstile off the chain
        // and keep it for ourselves.
        ts.link.remove();
        ts.reset();
    }

    td.turnstile_waiter = null;
    ts.waiters -= 1;

    td.waiting_on = null;
    td.lock.release_no_ipl();

    return waiter;
}
