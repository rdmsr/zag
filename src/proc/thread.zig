//! Higher-level thread management.
const rtl = @import("rtl");
const std = @import("std");
const r = @import("root");
const ex = r.ex;
const psp = r.ps.private;
const ke = r.ke;
const kep = ke.private;
const mm = r.mm;

pub const kernel_thread_stack_size = r.kib(16);

var reaper_item: ex.WorkItem = undefined;
var stack_item: ex.WorkItem = undefined;
var thread_zone: mm.zone.TypedZone(Thread) = undefined;

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

    // Wait until the thread finishes switching off its stack.
    const ipl = ketd.lock.acquire();
    ketd.lock.release(ipl);

    const td: *Thread = @fieldParentPtr("kern", ketd);

    psp.turnstile_zone.destroy(td.kern.turnstile);
    thread_zone.destroy(td);
}

fn reaper_fn(_: ?*anyopaque) void {
    ke.thread.reaper_list.process(reap_thread, null);
}

fn reaper_activation(_: *rtl.HandoffList) void {
    ex.work.enqueue(&reaper_item);
}

pub fn stack_activation() void {
    ex.work.enqueue(&stack_item);
}

pub fn init() void {
    thread_zone.init("thread", .{});
    ke.thread.reaper_list.* = .init(reaper_activation);
    reaper_item.init(.High, reaper_fn, null);
    stack_item.init(.High, stack_fn, null);
}

/// Create a kernel thread.
/// - `prio`: base priority of the thread.
/// - `entry`: entry point.
/// - `arg`: argument passed to `entry`.
pub fn create_kernel(
    prio: ke.Priority,
    continuation: ke.Continuation,
    start_with_stack: bool,
) !*Thread {
    var td = try thread_zone.create();

    const stack = if (start_with_stack)
        @intFromPtr(try mm.heap.alloc(kernel_thread_stack_size, .WaitForMemory)) +
            kernel_thread_stack_size
    else
        0;

    const turnstile = try psp.turnstile_zone.create();

    td.kern.init(.{
        .stack = stack,
        .turnstile = turnstile,
        .entry = continuation,
        .priority = prio,
    });

    return td;
}

/// Exit the currently running thread.
/// For now, this is just a wrapper over the kernel function.
pub fn exit() void {
    ke.thread.exit();
}

fn allocate_stack(obj: *anyopaque, _: ?*anyopaque) void {
    const link: **rtl.List.Entry = @ptrCast(@alignCast(obj));

    // Bleh
    const entry: *rtl.List.Entry = @fieldParentPtr("next", link);
    const thread: *ke.Thread = @fieldParentPtr("runq_link", entry);

    const stack = mm.heap.alloc(kernel_thread_stack_size, .WaitForMemory) catch
        unreachable;

    const stack_top = @intFromPtr(stack) + kernel_thread_stack_size;

    thread.context.reset(stack_top, ke.thread.call_continuation, thread);

    ke.sched.enqueue(thread);
}

fn stack_fn(_: ?*anyopaque) void {
    ke.thread.thread_stack_queue.process(allocate_stack, null);
}
