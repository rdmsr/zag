//! Implementation of generic wait mechanisms.
//! This is mostly based on the work by Arun Kishan on Windows 7.
//! See more here: https://youtu.be/OAAiOEQhsK0
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const kep = ke.private;

const std = @import("std");
const assert = std.debug.assert;

/// Header for waitable objects.
/// This must be added to any structured which is considered waitable.
pub const DispatchHeader = struct {
    pub const Type = enum {
        /// When signaled, `signaled` is kept high and all waiters are woken up.
        Notification,
        /// When signaled, `signaled` is decreased until 0, and a single waiter
        /// is woken up.
        Synchronization,
        /// Special type for queue objects.
        Queue,
    };

    /// List of WaitBlocks.
    waitblocks: rtl.List,
    /// Type of object.
    type: Type,
    /// Lock protecting the object.
    lock: ke.SpinLock,
    /// Signaled count.
    signaled: u32,

    /// Initialize a waitable object.
    pub fn init(obj: *DispatchHeader, kind: Type) void {
        obj.type = kind;
        obj.lock = ke.SpinLock.init("DispatchObject");
        obj.signaled = 0;
        obj.waitblocks.init();
    }

    fn consume(self: *DispatchHeader, td: *ke.Thread) void {
        switch (self.type) {
            .Synchronization => self.signaled -= 1,
            .Notification => {
                // Object remains signaled.
            },
            .Queue => {
                const q: *ke.Queue = @fieldParentPtr("hdr", self);
                const item = q.items.first();

                item.remove();
                q.hdr.signaled -= 1;
                _ = q.active.fetchAdd(1, .monotonic);

                td.queue_item = item;
            },
        }
    }

    fn can_satisfy(self: *DispatchHeader) bool {
        if (self.signaled == 0) return false;

        return switch (self.type) {
            .Notification, .Synchronization => true,
            .Queue => blk: {
                const q: *ke.Queue = @fieldParentPtr("hdr", self);
                break :blk q.active.load(.monotonic) < q.max_active;
            },
        };
    }
};

pub const WaitBlock = struct {
    pub const Status = enum(u8) {
        /// Block is linked to an object as part of a thread that is waiting.
        Active,
        /// The wait associated has been satisfied (or timed out).
        Inactive,
        /// A signal was delivered to the wait.
        Signaled,
    };
    /// List linkage.
    link: rtl.List.Entry,
    /// Object being waited on.
    object: *DispatchHeader,
    /// Thread that owns the WaitBlock.
    thread: *ke.Thread,
    /// Status of the WaitBlock.
    status: WaitBlock.Status,
};

/// Status of a wait operation.
pub const Status = enum(u8) {
    /// Wait is currently being processed.
    InProgress,
    /// Wait has been committed and is waiting for the object to be signaled.
    Committed,
    /// Wait has been satisfied (or timed out).
    Satisfied,
};

const Options = struct {
    timeout: ?rtl.Duration = null,
    waitblocks: ?[]WaitBlock = null,
    continuation: ?ke.Continuation = null,
};

/// Clean up waitblocks after a wait.
fn waitblocks_cleanup(blocks: []WaitBlock, initial_satisfier: ?usize) ?usize {
    var satisfier = initial_satisfier;

    for (blocks, 0..) |*wb, i| {
        const obj = wb.object;

        obj.lock.acquire_no_ipl();
        if (wb.status == .Active) {
            wb.status = .Inactive;
            wb.link.remove();
        } else if (wb.status == .Signaled) {
            assert(satisfier == null);
            satisfier = i;
        }

        obj.lock.release_no_ipl();
    }

    return satisfier;
}

/// Transition from one state to the next atomically.
/// Return if the state transition was successful.
fn transition(td: *ke.Thread, from: Status, to: Status) bool {
    return td.wait_status.cmpxchgStrong(from, to, .acq_rel, .monotonic) == null;
}

/// Wait for the provided object to be signaled.
/// This will only return an error if `timeout` is provided and
/// the wait times out.
pub fn wait_one(
    object: *DispatchHeader,
    reason: []const u8,
    opts: Options,
) !usize {
    var objects = [_]*DispatchHeader{object};
    return wait_any(&objects, reason, opts);
}

/// Wait for any of the provided objects to be signaled.
/// Returns the index of the object that was signaled, or an error
/// in the case of timeout.
/// If `timeout` is not provided, it will wait indefinitely.
/// If `waitblocks` is specified, then the wait will use those waitblocks
/// for the operation. Note that if `timeout` is provided, then one additional
/// waitblock must be allocated.
pub fn wait_any(
    objects: []const *DispatchHeader,
    reason: []const u8,
    opts: Options,
) !usize {
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    const curtd = ke.thread.current();
    const obj_count = objects.len;
    const has_timeout = opts.timeout != null;
    const total_count = obj_count + @intFromBool(has_timeout);
    const timer = &curtd.timer;
    const blocks = opts.waitblocks orelse &curtd.inner_waitblocks;
    assert(total_count <= blocks.len);

    var is_queue = false;
    var satisfier: ?usize = null;
    var installed_count: usize = 0;

    // Prepare the wait.
    curtd.wait_status.store(.InProgress, .monotonic);

    if (has_timeout) timer.init();

    for (0..total_count) |i| {
        const obj = if (i == objects.len) &timer.hdr else objects[i];
        const wb = &blocks[i];

        obj.lock.acquire_no_ipl();
        defer obj.lock.release_no_ipl();

        if (obj.can_satisfy()) {
            // Object was already signaled. Try consuming it.
            if (transition(curtd, .InProgress, .Satisfied)) {
                obj.consume(curtd);
                satisfier = i;
            }
            // We have already been satisfied in the meantime, abort.
            break;
        }

        is_queue = is_queue or obj.type == .Queue;

        wb.object = obj;
        wb.thread = curtd;
        wb.status = .Active;

        // We are not satisfied yet, so add a waitblock to the object.
        obj.waitblocks.insert_tail(&wb.link);
        installed_count += 1;
    }

    // Wait was already satisfied, back out.
    if (satisfier != null or (has_timeout and opts.timeout.?.value == 0)) {
        if (satisfier != null) {
            assert(curtd.wait_status.load(.acquire) == .Satisfied);
        }

        // Remove any wait block we might've installed.
        return waitblocks_cleanup(blocks[0..installed_count], satisfier) orelse
            error.Timeout;
    }

    curtd.waitblocks = blocks;
    curtd.wait_count = installed_count;
    curtd.timeout_block = @intCast(obj_count);
    curtd.has_timeout = has_timeout;

    if (opts.timeout) |timeout| ke.timer.set(timer, timeout, .{});

    curtd.lock.acquire_no_ipl();

    // Now try committing the wait.
    // A signal may have satisfied the wait after we released the object locks.
    // We need to re-check the state of the wait before actually blocking.
    if (transition(curtd, .InProgress, .Committed)) {
        if (!is_queue) {
            if (curtd.queue) |q| {
                kep.queue.signal_wait(q);
            }
        }

        curtd.wait_reason = reason;

        // We're good, now actually block.
        kep.sched.block_locked(curtd, opts.continuation);
    } else {
        // Could not commit.
        curtd.lock.release_no_ipl();
    }

    return post_wait(curtd);
}

/// Satisfy a wait on an object.
pub fn satisfy_wait(obj: *DispatchHeader) void {
    assert(obj.lock.is_locked());

    const all = obj.type == .Notification;

    // Go through (potentially) all wait blocks and try to satisfy them.
    while (!obj.waitblocks.is_empty() and obj.can_satisfy()) {
        // Get the first waitblock from the list.
        var wb: *WaitBlock = @fieldParentPtr("link", obj.waitblocks.first());
        var td = wb.thread;

        assert(wb.status == .Active);
        assert(wb.object == obj);

        // Remove it.
        wb.link.remove();

        // Three cases may occur here:
        // 1. The wait was still preparing (.InProgress) and we interrupted it.
        // 2. The wait was already committed (.Committed) and we satisfied it.
        // 3. The wait was already satisfied by another object (.Satisfied).

        // 1.
        if (transition(td, .InProgress, .Satisfied)) {
            // We interrupted the wait while it was being prepared.
            wb.status = .Signaled;
            obj.consume(td);
        }

        // 2.
        else if (transition(td, .Committed, .Satisfied)) {
            // We interrupted the wait while it was committed.
            // Wake the thread.
            wb.status = .Signaled;
            obj.consume(td);

            const ipl = td.lock.acquire();

            if (obj.type != .Queue) {
                if (td.queue) |q| {
                    kep.queue.signal_wake(q);
                }
            }

            kep.sched.unblock_locked(td);
            td.lock.release(ipl);
        }

        // 3.
        else if (td.wait_status.load(.acquire) == .Satisfied) {
            // Someone else satisfied the wait, deactivate the wait block.
            wb.status = .Inactive;
            continue;
        }

        if (!all) {
            break;
        }
    }
}

pub fn post_wait(thread: *ke.Thread) !usize {
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    const has_timeout = thread.has_timeout;

    // We're back!
    // Stop the timer if it was set.
    if (has_timeout) {
        ke.timer.cancel(&thread.timer);
    }

    const wait_count = thread.wait_count;
    const timeout_block = thread.timeout_block;
    const blocks = thread.waitblocks[0..wait_count];

    thread.has_timeout = false;
    thread.wait_reason = null;
    thread.wait_count = 0;
    thread.timeout_block = 0;

    // Find the object that satisfied us.
    const final_sat = waitblocks_cleanup(blocks, null) orelse
        return error.Timeout;

    return if (has_timeout and final_sat == timeout_block)
        error.Timeout
    else
        final_sat;
}
