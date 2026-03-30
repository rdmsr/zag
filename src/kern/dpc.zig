const std = @import("std");
const config = @import("config");
const rtl = @import("rtl");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

/// Deferred Procedure Call (DPC) structure.
/// Used for scheduling work to be done when IPL is lowered below `ke.Ipl.Dispatch`.
pub const Dpc = struct {
    /// Entry into per-CPU DPC queue
    link: rtl.List.Entry,
    /// Routine to call
    func: *const fn (?*anyopaque) void,
    /// Argument passed to the routine
    arg: ?*anyopaque,
    /// Whether or not the DPC is currently inserted
    inserted: bool,

    /// Initialize a DPC for `func`.
    pub fn init(func: *const fn (?*anyopaque) void) Dpc {
        return .{
            .link = undefined,
            .func = func,
            .arg = undefined,
            .inserted = false,
        };
    }
};

const PerCpu = struct {
    /// Queue of DPCs on this CPU.
    queue: rtl.List,
    /// Lock over this CPU's DPC queue.
    lock: ke.SpinLock,
};

const pcpu = ke.CpuLocal(PerCpu, .{
    .lock = .init(),
    .queue = undefined,
});

export const dpc_percpu_init linksection(b.percpu_init) = &pcpu_init;

fn pcpu_init() linksection(b.init) callconv(.c) void {
    pcpu.local().queue.init();
}

/// Enqueue a DPC.
/// If the DPC is already enqueued, this function is a no-op.
pub fn enqueue(dpc: *Dpc, arg: ?*anyopaque) void {
    const ipl = ke.ipl.raise(.High);
    const mycpu = ke.cpu.current();
    const dpc_cpu = pcpu.local();

    if (!dpc.inserted) {
        dpc.arg = arg;

        // Insert the DPC on this CPU's DPC queue
        dpc_cpu.lock.acquire_no_ipl();
        dpc_cpu.queue.insert_tail(&dpc.link);

        // Mark the DPC as pending on this CPU
        ki.ipl.set_softint_pending(mycpu, .Dispatch);

        dpc.inserted = true;
        dpc_cpu.lock.release_no_ipl();
    }

    ke.ipl.lower(ipl);
}

fn dispatch_queue(cpu: u32) void {
    const ipl_cpu = ki.ipl.percpu.remote(cpu);
    const dpc_cpu = pcpu.remote(cpu);
    const sched_cpu = ki.sched.percpu.remote(cpu);

    ipl_cpu.ipl = .Dispatch;

    // Mark as handled, this must be done before enabling interrupts or we will race.
    ki.ipl.clear_softint_pending(cpu, .Dispatch);

    _ = ki.impl.enable_interrupts();

    while (true) {
        const ipl = dpc_cpu.lock.acquire_at(.High);
        var dpc: *Dpc = undefined;

        if (dpc_cpu.queue.is_empty()) {
            // No more DPCs to process.
            dpc_cpu.lock.release(ipl);
            break;
        }

        // Pop the head
        var first_elem = dpc_cpu.queue.first();
        first_elem.remove();

        dpc = @fieldParentPtr("link", first_elem);
        dpc.inserted = false;

        // An interrupt which would enqueue this DPC could occur between loading the argument and calling the routine,
        // which is why we capture it here to ensure that we get the intended context.
        const arg = dpc.arg;

        dpc_cpu.lock.release(ipl);
        std.debug.assert(ke.ipl.current() == .Dispatch);

        dpc.func(arg);
    }

    if (sched_cpu.start_timer) {
        ke.timer.set(&sched_cpu.resched_timer, std.time.ns_per_ms * config.CONFIG_SCHED_TIMESLICE, &sched_cpu.resched_dpc);
    }

    if (sched_cpu.preemption_reason == .HigherPriority) {
        // Reload the quantum for the new thread.
        ke.timer.cancel(&sched_cpu.resched_timer);
        ke.timer.set(&sched_cpu.resched_timer, std.time.ns_per_ms * config.CONFIG_SCHED_TIMESLICE, &sched_cpu.resched_dpc);
    }

    sched_cpu.start_timer = false;
    sched_cpu.preemption_reason = .None;

    if (sched_cpu.next_thread != null) {
        ki.sched.handle_preemption(sched_cpu);
    }

    _ = ki.impl.disable_interrupts();
}

/// Dispatch the DPC queue on `cpu`.
pub fn dispatch(cpu: u32) void {
    // DPC processing is done at Ipl.Dispatch
    // We can't call lower/raise here because they might call us again recursively.
    var mycpu = cpu;
    const old_ipl = ki.ipl.percpu.remote(mycpu).ipl;
    const int_state = ki.impl.disable_interrupts();

    while (ki.ipl.is_softint_pending(.Dispatch)) {
        dispatch_queue(mycpu);
        // Our CPU might have changed.
        mycpu = ke.cpu.current();
    }

    ki.ipl.percpu.remote(mycpu).ipl = old_ipl;

    ki.impl.restore_interrupts(int_state);
}
