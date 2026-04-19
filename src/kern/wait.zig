//! Implementation of generic wait mechanisms.
//! This is mostly based on the work by Arun Kishan on Windows 7.
//! See more here: https://youtu.be/OAAiOEQhsK0
const rtl = @import("rtl");
const std = @import("std");
const r = @import("root");
const ke = r.ke;
const ki = ke.private;

/// Header for waitable objects.
/// This must be added to any structured which is considered waitable.
pub const DispatchHeader = struct {
    pub const Type = enum {
        /// When signaled, `signaled` is kept high and all waiters are woken up.
        Notification,
        /// When signaled, `signaled` is decreased until 0, and a single waiter is woken up.
        Synchronization,
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
        obj.lock = ke.SpinLock.init();
        obj.signaled = 0;
        obj.waitblocks.init();
    }

    fn consume(self: *DispatchHeader) void {
        switch (self.type) {
            .Synchronization => self.signaled -= 1,
            .Notification => {
                // Object remains signaled.
            },
        }
    }
};

pub const WaitBlock = struct {
    pub const Status = enum(u8) {
        /// WaitBlock is linked to an object as part of a thread that is waiting.
        Active,
        /// The wait associated with this WaitBlock has been satisfied (or timed out).
        Inactive,
        /// A signal was delivered to the wait (this could be before it was committed).
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

/// Wait for the provided object to be signaled.
pub fn wait_one(object: *DispatchHeader, timeout: ?r.Nanoseconds) !usize {
    var objects = [_]*DispatchHeader{object};
    return wait_any(&objects, timeout, null);
}

/// Wait for any of the provided objects to be signaled.
/// Returns the index of the object that was signaled, or an error.
/// If `timeout` is not provided, it will wait indefinitely.
/// If `waitblocks` is specified, then the wait will use those waitblocks for the operation.
/// Note that if `timeout` is provided, then one additional waitblock must be allocated.
pub fn wait_any(objects: []*DispatchHeader, timeout: ?r.Nanoseconds, waitblocks: ?[*]WaitBlock) !usize {
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);
    const curtd = ki.sched.percpu.local().current_thread.?;
    const obj_count = objects.len;
    const has_timeout = timeout != null;
    const blocks = waitblocks orelse blk: {
        std.debug.assert(obj_count <= curtd.waitblocks.len - @intFromBool(has_timeout));
        break :blk &curtd.waitblocks;
    };

    const total_count = obj_count + @intFromBool(has_timeout);
    const timer_i = obj_count;
    const timer = &curtd.timer;
    const timer_block = &curtd.waitblocks[3];

    var satisfier: ?usize = null;
    curtd.wait_status.store(.InProgress, .release);

    for (0..total_count) |i| {
        const is_timer = has_timeout and i == timer_i;
        var obj = if (is_timer) &timer.hdr else objects[i];
        var wb = if (is_timer) timer_block else &blocks[i];

        obj.lock.acquire_no_ipl();
        defer obj.lock.release_no_ipl();

        if (obj.signaled > 0) {
            // Object was already signaled. Try consuming it.
            if (curtd.wait_status.cmpxchgStrong(.InProgress, .Satisfied, .acq_rel, .monotonic) == null) {
                obj.consume();
            }
            // We have already been satisfied in the meantime, abort.
            satisfier = i;
            break;
        }

        wb.object = obj;
        wb.thread = curtd;
        wb.status = .Active;
        // We are not satisfied yet, so add a waitblock to the object's waitblocks
        obj.waitblocks.insert_tail(&wb.link);
    }

    // Wait was already satisfied, back out.
    if (satisfier != null or (has_timeout and timeout.? == 0)) {
        std.debug.assert(curtd.wait_status.load(.acquire) == .Satisfied);

        if (satisfier) |sat| {
            // Remove any wait block we might've installed
            for (0..sat) |i| {
                const is_timer = has_timeout and i == timer_i;
                var obj = if (is_timer) &timer.hdr else objects[i];
                var wb = if (is_timer) timer_block else &blocks[i];

                obj.lock.acquire_no_ipl();
                wb.status = .Inactive;
                wb.link.remove();
                obj.lock.release_no_ipl();
            }
        }

        return satisfier orelse error.Timeout;
    }

    if (has_timeout) {
        ke.timer.set(timer, timeout.?, null);
    }

    // Now try committing the wait.
    // While we're trying to commit the wait, the object locks have been released, and the state could therefore change.
    // We need to re-check the state of the wait before actually blocking.
    if (curtd.wait_status.cmpxchgStrong(.InProgress, .Committed, .acq_rel, .monotonic) == null) {
        // We're good, now actually block.
        ke.sched.block();
    }

    // We're back!
    // Stop the timer if it was set.
    if (has_timeout) {
        ke.timer.cancel(timer);
    }

    // Find the object that satisfied us.
    for (0..total_count) |i| {
        const is_timer = has_timeout and i == timer_i;
        var obj = if (is_timer) &timer.hdr else objects[i];
        var wb = if (is_timer) timer_block else &blocks[i];

        obj.lock.acquire_no_ipl();
        if (wb.status == .Active) {
            // Waitblock is still active, remove it from the list.
            wb.link.remove();
        }
        if (wb.status == .Signaled) {
            // This waitblock was signaled, it must be the one that satisfied the wait.
            std.debug.assert(satisfier == null);
            satisfier = i;
        }
        // Ignore inactive waitblocks
        obj.lock.release_no_ipl();
    }

    const final_sat = satisfier orelse return error.Timeout;
    return if (has_timeout and final_sat == timer_i) error.Timeout else final_sat;
}

/// Satisfy a wait on an object.
pub fn satisfy_wait(obj: *DispatchHeader) void {
    const all = obj.type == .Notification;

    // Go through (potentially) all wait blocks and try to satisfy them.
    while (!obj.waitblocks.is_empty() and obj.signaled > 0) {
        // Get the first waitblock from the list.
        var wb: *WaitBlock = @fieldParentPtr("link", obj.waitblocks.first());
        var td = wb.thread;

        // Remove it.
        wb.link.remove();

        // Three cases may occur here:
        // 1. The wait was still preparing (status == .InProgress) and we interrupted it.
        // 2. The wait was already committed (status == .Committed) and we satisfied it.
        // 3. The wait was already satisfied by another object (status == .Satisfied).

        // 1.
        if (td.wait_status.cmpxchgStrong(.InProgress, .Satisfied, .acq_rel, .monotonic) == null) {
            // We interrupted the wait while it was being prepared.
            wb.status = .Signaled;
            obj.consume();
        }

        // 2.
        else if (td.wait_status.cmpxchgStrong(.Committed, .Satisfied, .acq_rel, .monotonic) == null) {
            // We interrupted the wait while it was committed.
            // Wake the thread.
            wb.status = .Signaled;
            obj.consume();
            ke.sched.unblock(td);
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
