//! Higher-level thread management.
const rtl = @import("rtl");
const std = @import("std");
const r = @import("root");
const ex = r.ex;
const psp = r.ps.private;
const ke = r.ke;
const ki = ke.private;
const mm = r.mm;

const kernel_thread_stack_size = r.kib(16);

var reaper_item: ex.WorkItem = undefined;

/// Higher-level wrapper over a thread.
pub const Thread = struct {
    /// Lower-level part of the thread.
    kern: ke.Thread,
};

fn reap_thread(obj: *anyopaque, _: ?*anyopaque) void {
    const link: **rtl.List.Entry = @ptrCast(@alignCast(obj));

    // Bleh
    const entry: *rtl.List.Entry = @fieldParentPtr("next", link);
    const ketd: *ke.Thread = @fieldParentPtr("runq_link", entry);
    const td: *Thread = @fieldParentPtr("kern", ketd);

    psp.turnstile_zone.destroy(td.kern.turnstile);
    mm.heap.free(td.kern.stack, kernel_thread_stack_size);
    mm.zone.gpa.destroy(td);
}

fn reaper_fn(_: ?*anyopaque) void {
    ke.thread.reaper_list.process(reap_thread, null);
}

fn activation(_: *rtl.HandoffList) void {
    ex.workqueue.enqueue(&reaper_item);
}

pub fn init() void {
    ke.thread.reaper_list.* = .init(activation);
    reaper_item.init(.High, reaper_fn, null);
}

/// Create a kernel thread.
/// - `prio`: base priority of the thread.
/// - `entry`: entry point.
/// - `arg`: argument passed to `entry`.
pub fn create_kernel(prio: u8, entry: *const fn (arg: ?*anyopaque) void, arg: ?*anyopaque) !*Thread {
    var td = try mm.zone.gpa.create(Thread);
    const stack = try mm.heap.alloc(kernel_thread_stack_size);

    td.kern.init(@intFromPtr(stack), kernel_thread_stack_size, prio, entry, arg);
    td.kern.turnstile = try psp.turnstile_zone.create();

    return td;
}

/// Exit the currently running thread.
/// For now, this is just a wrapper over the kernel function.
pub fn exit() void {
    ke.thread.exit();
}
