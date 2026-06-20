//! Scheduler-aware queue.
//! This file implements a queue onto which threads can block.
//! The queue is aware of its threads blocking and waking up, and supports
//! a maximum concurrency cap, controlling how many threads can process items
//! from the queue concurrently.
//! This is a bit similar to the KQUEUE data structure in the NT kernel.

const r = @import("root");
const rtl = @import("rtl");
const ke = r.ke;
const ki = ke.private;
const std = @import("std");

pub const Queue = struct {
    hdr: ki.wait.DispatchHeader,
    items: rtl.List,
    active: usize,
    max_active: usize,

    /// Initialize a queue.
    pub fn init(self: *Queue, max_active: usize) void {
        self.* = .{
            .items = undefined,
            .active = 0,
            .max_active = max_active,
            .hdr = undefined,
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

        ki.wait.satisfy_wait(&self.hdr);
    }

    /// Remove the item at the head.
    /// This blocks until an item is actually popped.
    pub fn remove(self: *Queue) *rtl.List.Entry {
        const ipl = self.hdr.lock.acquire();
        const td = ki.sched.percpu.local().current_thread.?;

        if (td.queue) |q| {
            std.debug.assert(q == self);
            std.debug.assert(self.active > 0);

            self.active -= 1;
            if (self.hdr.signaled > 0 and self.active < self.max_active) {
                ki.wait.satisfy_wait(&self.hdr);
            }
        } else {
            td.queue = self;
        }

        td.queue_item = null;

        self.hdr.lock.release(ipl);

        // Wait until the queue has something for us.
        _ = ke.wait.wait_one(&self.hdr, null) catch unreachable;

        // Grab the queue item and set it to null.
        const ret = td.queue_item orelse unreachable;
        td.queue_item = null;
        return ret;
    }
};

/// Called when one of the threads on the queue has blocked on something other
/// than the queue.
pub fn signal_wait(queue: *Queue) void {
    const ipl = queue.hdr.lock.acquire();
    std.debug.assert(queue.active > 0);

    queue.active -= 1;

    if (queue.hdr.signaled > 0 and queue.active < queue.max_active) {
        ki.wait.satisfy_wait(&queue.hdr);
    }

    queue.hdr.lock.release(ipl);
}

/// Called when one of the threads on the queue has woken back up.
pub fn signal_wake(queue: *Queue) void {
    const ipl = queue.hdr.lock.acquire();
    queue.active += 1;
    queue.hdr.lock.release(ipl);
}
