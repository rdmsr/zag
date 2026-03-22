const std = @import("std");
const rtl = @import("rtl");
const b = @import("base");
const ke = b.ke;
const ki = b.ke.private;

comptime {
    if (!@hasDecl(ki.impl, "Cpu")) @compileError("impl must provide Cpu");
}

pub const ThreadStatus = packed struct(u8) {
    interactive: bool,
    priority: u7,
};

pub const PreemptionReason = enum(u8) {
    None,
    /// A higher priority thread was readied.
    HigherPriority,
};

/// Per-CPU state
pub const Cpu = struct {
    /// Implementation-dependent CPU data.
    impl: ki.impl.Cpu,
    /// Unique ID of this CPU.
    id: u32,
    /// Current IPL on this CPU.
    ipl: ke.Ipl,
    /// Bitmask of pending software interrupts on this CPU.
    pending_softints: std.atomic.Value(u8),
    /// Currently running thread.
    current_thread: ?*ke.Thread,
    /// Atomic byte for getting the current thread's status locklessly.
    /// 1 bit for thread interactivity, 7 for priority.
    current_thread_status: std.atomic.Value(ThreadStatus),
    /// Per-CPU idle thread.
    idle_thread: ?*ke.Thread,
    /// Thread selected for preemption.
    next_thread: ?*ke.Thread,
    /// The reason why the current thread was preempted.
    preemption_reason: PreemptionReason,
    /// Flag indicating the start of the scheduling timer.
    start_timer: bool,
    /// Queue of DPCs on this CPU.
    dpc_queue: rtl.List,
    /// Lock over this CPU's DPC queue.
    dpc_lock: ke.SpinLock,
    /// Heap of pending timers on this CPU.
    timers_heap: rtl.PairingHeap(.min, ki.timer.cmp_timer),
    /// Lock over the timer heap.
    timers_lock: ke.SpinLock,
    /// Per-CPU scheduler state.
    sched_data: ki.sched.PerCpu,
    /// DPCs
    resched_dpc: ke.Dpc,
    timer_dpc: ke.Dpc,
    resched_timer: ke.Timer,

    /// Initialize `cpu` for usage with its idle thread being `thread`.
    pub fn init(cpu: *Cpu, thread: *ke.Thread) void {
        cpu.* = .{
            .id = cpu.id,
            .ipl = .Zero,
            .pending_softints = .init(0),
            .idle_thread = thread,
            .current_thread = thread,
            .timer_dpc = .init(ki.timer.handle_expiry),
            .resched_dpc = .init(ki.sched.clock),
            .timers_heap = .init(),
            .current_thread_status = .init(.{ .interactive = false, .priority = 0 }),
            .next_thread = null,
            .dpc_lock = .init(),
            .preemption_reason = .None,
            .start_timer = false,
            .dpc_queue = undefined,
            .timers_lock = .init(),
            .sched_data = undefined,
            .resched_timer = undefined,
            .impl = cpu.impl,
        };

        cpu.dpc_queue.init();
        cpu.resched_timer.init();

        ki.sched.init_cpu(&cpu.sched_data);
    }
};
