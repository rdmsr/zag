const std = @import("std");
const rtl = @import("rtl");
const b = @import("base");
const ke = b.ke;
const ki = b.ke.private;

comptime {
    if (!@hasDecl(ki.impl, "Cpu")) @compileError("impl must provide Cpu");
}

pub const PreemptionReason = enum(u8) {
    None,
    /// A higher priority thread was readied.
    HigherPriority,
};

extern var __init_array_percpu_start: u8;
extern var __init_array_percpu_end: u8;

/// Global Per-CPU state.
pub const Cpu = struct {
    /// Implementation-dependent CPU data.
    impl: ki.impl.Cpu,
    /// Unique ID of this CPU.
    id: u32,
    /// Current IPL on this CPU.
    ipl: ke.Ipl,
    /// Currently running thread.
    current_thread: ?*ke.Thread,
    /// Per-CPU idle thread.
    idle_thread: ?*ke.Thread,
    /// Thread selected for preemption.
    next_thread: ?*ke.Thread,
    /// The reason why the current thread was preempted.
    preemption_reason: PreemptionReason,
    /// Flag indicating the start of the scheduling timer.
    start_timer: bool,
    /// DPCs
    resched_dpc: ke.Dpc,
    resched_timer: ke.Timer,

    /// Initialize `cpu` for usage with its idle thread being `thread`.
    pub fn init(cpu: *Cpu, thread: *ke.Thread) void {
        cpu.* = .{
            .id = cpu.id,
            .ipl = .Passive,
            .idle_thread = thread,
            .current_thread = thread,
            .resched_dpc = .init(ki.sched.clock),
            .next_thread = null,
            .preemption_reason = .None,
            .start_timer = false,
            .resched_timer = undefined,
            .impl = cpu.impl,
        };

        // Call per-cpu init functions.
        const start = @intFromPtr(&__init_array_percpu_start);
        const end = @intFromPtr(&__init_array_percpu_end);
        const count = (end - start) / @sizeOf(*const fn () void);
        const funcs: [*]const *const fn () callconv(.c) void = @ptrFromInt(start);

        for (0..count) |i| {
            funcs[i]();
        }

        cpu.resched_timer.init();
    }
};

comptime {
    if (!@hasDecl(ki.impl, "percpu_ptr")) @compileError("impl must provide percpu_ptr()");
    if (!@hasDecl(ki.impl, "percpu_ptr_other")) @compileError("impl must provide percpu_ptr_other()");
}

/// Wraps around CPU-local data.
pub fn CpuLocal(comptime T: type, comptime init: T) type {
    return struct {
        var storage: T linksection(".data.percpu") = init;

        /// Return a pointer to local CPU data.
        pub fn local() @TypeOf(ki.impl.percpu_ptr(&storage)) {
            return ki.impl.percpu_ptr(&storage);
        }

        /// Return a pointer to remote CPU data.
        pub fn remote(cpu: *ke.Cpu) *T {
            return ki.impl.percpu_ptr_other(&storage, cpu.id);
        }
    };
}
