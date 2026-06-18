//! Higher-level thread management.
const r = @import("root");
const psp = r.ps.private;
const ke = r.ke;
const ki = ke.private;
const mm = r.mm;

const kernel_thread_stack_size = r.kib(16);

/// Higher-level wrapper over a thread.
pub const Thread = struct {
    /// Lower-level part of the thread.
    kern: ke.Thread,
};

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
