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
                q.active += 1;

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
                break :blk q.active < q.max_active;
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

    const blocks = opts.waitblocks orelse blk: {
        assert(total_count <= curtd.inner_waitblocks.len);
        break :blk &curtd.inner_waitblocks;
    };

    const timer_i = obj_count;
    const timer = &curtd.timer;

    var queue: ?*ke.Queue = null;
    var satisfier: ?usize = null;

    curtd.wait_status.store(.InProgress, .monotonic);

    if (has_timeout) {
        timer.init();
    }

    var installed_count: usize = 0;

    for (0..total_count) |i| {
        const is_timer = has_timeout and i == timer_i;
        const obj = if (is_timer) &timer.hdr else objects[i];
        const wb = &blocks[i];

        obj.lock.acquire_no_ipl();
        defer obj.lock.release_no_ipl();

        if (obj.can_satisfy()) {
            // Object was already signaled. Try consuming it.
            if (curtd.wait_status.cmpxchgStrong(
                .InProgress,
                .Satisfied,
                .acq_rel,
                .monotonic,
            ) == null) {
                obj.consume(curtd);
                satisfier = i;
            }

            // We have already been satisfied in the meantime, abort.
            break;
        }

        if (obj.type == .Queue) {
            queue = @fieldParentPtr("hdr", obj);
        }

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
        for (0..installed_count) |i| {
            const is_timer = has_timeout and i == timer_i;
            const obj = if (is_timer) &timer.hdr else objects[i];
            const wb = &blocks[i];

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

        return satisfier orelse error.Timeout;
    }

    curtd.waitblocks = blocks;
    curtd.wait_count = installed_count;
    curtd.timeout_block = @intCast(obj_count);
    curtd.has_timeout = has_timeout;

    if (opts.timeout) |timeout| {
        ke.timer.set(timer, timeout, .{});
    }

    curtd.lock.acquire_no_ipl();

    // Now try committing the wait.
    // While we're trying to commit the wait, the object locks
    // have been released, and the state could therefore change.
    // We need to re-check the state of the wait before actually blocking.
    if (curtd.wait_status.cmpxchgStrong(
        .InProgress,
        .Committed,
        .acq_rel,
        .monotonic,
    ) == null) {
        if (queue == null) {
            if (curtd.queue) |q| {
                kep.queue.signal_wait(q);
            }
        }

        curtd.wait_reason = reason;

        // We're good, now actually block.
        kep.sched.block_locked(curtd, opts.continuation);
    } else {
        queue = null;

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
        if (td.wait_status.cmpxchgStrong(
            .InProgress,
            .Satisfied,
            .acq_rel,
            .monotonic,
        ) == null) {
            // We interrupted the wait while it was being prepared.
            wb.status = .Signaled;
            obj.consume(td);
        }

        // 2.
        else if (td.wait_status.cmpxchgStrong(
            .Committed,
            .Satisfied,
            .acq_rel,
            .monotonic,
        ) == null) {
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

    var satisfier: ?usize = null;
    const has_timeout = thread.has_timeout;

    // We're back!
    // Stop the timer if it was set.
    if (has_timeout) {
        ke.timer.cancel(&thread.timer);
    }

    const wait_count = thread.wait_count;
    const timeout_block = thread.timeout_block;

    thread.has_timeout = false;
    thread.wait_reason = null;
    thread.wait_count = 0;
    thread.timeout_block = 0;

    // Find the object that satisfied us.
    for (0..wait_count) |i| {
        const wb = &thread.waitblocks[i];
        var obj = wb.object;

        obj.lock.acquire_no_ipl();

        if (wb.status == .Active) {
            // Waitblock is still active, remove it from the list.
            wb.link.remove();
        }
        if (wb.status == .Signaled) {
            // This waitblock was signaled, it must be the one that satisfied
            // the wait.
            assert(satisfier == null);
            satisfier = i;
        }
        // Ignore inactive waitblocks
        obj.lock.release_no_ipl();
    }

    const final_sat = satisfier orelse return error.Timeout;
    return if (has_timeout and final_sat == timeout_block)
        error.Timeout
    else
        final_sat;
}
