//! Scheduler-aware queue.
//! This file implements a queue onto which threads can block.
//! The queue is aware of its threads blocking and waking up, and supports
//! a maximum concurrency cap, controlling how many threads can process items
//! from the queue concurrently.
//! This is a bit similar to the KQUEUE data structure in the NT kernel.

const r = @import("root");
const rtl = @import("rtl");
const ke = r.ke;
const kep = ke.private;

const std = @import("std");
const assert = std.debug.assert;

pub const Queue = struct {
    hdr: kep.wait.DispatchHeader,
    items: rtl.List,
    active: std.atomic.Value(usize),
    max_active: usize,
    dpc: ke.Dpc,

    /// Initialize a queue.
    pub fn init(self: *Queue, max_active: usize) void {
        self.* = .{
            .items = undefined,
            .active = std.atomic.Value(usize).init(0),
            .max_active = max_active,
            .hdr = undefined,
            .dpc = ke.Dpc.init(queue_dpc),
        };

        self.hdr.init(.Queue);
        self.items.init();
    }

    pub const Position = enum { Head, Tail };

    /// Insert `item` into the queue at the desired position.
    pub fn insert(self: *Queue, item: *rtl.List.Entry, pos: Position) void {
        const ipl = self.hdr.lock.acquire();
        defer self.hdr.lock.release(ipl);

        self.hdr.signaled += 1;

        switch (pos) {
            .Head => {
                self.items.insert_head(item);
            },

            .Tail => {
                self.items.insert_tail(item);
            },
        }

        kep.wait.satisfy_wait(&self.hdr);
    }

    /// Remove the item at the head.
    /// This blocks until an item is actually popped.
    pub fn remove(self: *Queue, timeout: ?rtl.Duration) !*rtl.List.Entry {
        const ipl = self.hdr.lock.acquire();
        const td = kep.sched.percpu.local().current_thread orelse unreachable;

        if (td.queue) |q| {
            assert(q == self);
            assert(self.active.load(.monotonic) > 0);

            const old_active = self.active.fetchSub(1, .monotonic);

            if (self.hdr.signaled > 0 and old_active <= self.max_active) {
                kep.wait.satisfy_wait(&self.hdr);
            }
        } else {
            td.queue = self;
        }

        td.queue_item = null;

        self.hdr.lock.release(ipl);

        // Wait until the queue has something for us.
        _ = ke.wait.wait_one(&self.hdr, "queue", .{
            .timeout = timeout,
        }) catch |err| {
            if (err == error.Timeout and timeout.?.value == 0) {
                // Polled for an item and found nothing, ensure active is
                // restored (it was decremented earlier).
                signal_wake(self);
            }
            return err;
        };

        // Grab the queue item and set it to null.
        const ret = td.queue_item orelse unreachable;
        td.queue_item = null;
        return ret;
    }
};

fn queue_dpc(dpc: *ke.Dpc, _: ?*anyopaque) void {
    const queue: *Queue = @fieldParentPtr("dpc", dpc);
    queue.hdr.lock.acquire_no_ipl();

    // Wake all possible waiters.
    while (queue.hdr.signaled > 0 and
        !queue.hdr.waitblocks.is_empty() and
        queue.active.load(.monotonic) < queue.max_active)
    {
        kep.wait.satisfy_wait(&queue.hdr);
    }

    queue.hdr.lock.release_no_ipl();
}

/// Called when one of the threads on the queue has blocked on something other
/// than the queue.
pub fn signal_wait(queue: *Queue) void {
    assert(queue.active.load(.monotonic) > 0);

    const old_active = queue.active.fetchSub(1, .monotonic);

    if (old_active <= queue.max_active) {
        // Need to enqueue a DPC here because we can't hold the queue lock.
        // This is because this code is called in waiting code with the thread
        // lock held (i.e when the thread has committed a wait), and this would
        // break the dispatch object -> thread lock ordering we currently have.
        // Enqueuing a DPC does mean that there could be some latency when
        // before waking replacement workers, but this shouldn't be a big issue,
        // hopefully.

        ke.dpc.enqueue(&queue.dpc, null);
    }
}

/// Called when one of the threads on the queue has woken back up.
pub fn signal_wake(queue: *Queue) void {
    _ = queue.active.fetchAdd(1, .monotonic);
}
