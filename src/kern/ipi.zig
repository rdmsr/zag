//! Generic cross-core call mechanisms.

const r = @import("root");
const std = @import("std");

const ke = r.ke;
const ki = r.ki;
const pl = r.pl;

const State = enum(u8) {
    /// Not currently processing IPIs.
    Idle = 0,
    /// Has IPIs pending.
    Pending = 1,
    /// Is currently processing IPIs.
    Running = 2,
};

const PerCpu = struct {
    /// Function to be called on other CPUs.
    func: *const fn (u32, ?*anyopaque) void,
    /// Argument passed to the function.
    arg: ?*anyopaque,
    /// Pending work from other CPUs.
    pending: ke.AtomicCpuMask,
    /// Pending CPUs.
    counter: std.atomic.Value(u16),
    /// IPI state.
    state: std.atomic.Value(State),
};

const percpu = ke.CpuLocal(PerCpu, undefined);

/// Call a function on another CPU.
/// The function will be executed synchronously, i.e this will block until
/// the function finishes running. The callback is called with the sender cpu
/// and provided argument as arguments.
pub fn unicast(
    cpu: u32,
    func: *const fn (u32, ?*anyopaque) void,
    arg: ?*anyopaque,
) void {
    const ipl = ke.ipl.raise(.Dispatch);
    const curcpu = percpu.local();
    const remote = percpu.remote(cpu);

    curcpu.func = func;
    curcpu.arg = arg;
    curcpu.counter.store(1, .monotonic);

    remote.pending.set(ke.cpu.current(), .monotonic);

    const state = remote.state.swap(.Pending, .release);

    if (state == .Idle) {
        std.log.info("Sent ipi", .{});
        pl.send_ipi(cpu);
    }

    while (curcpu.counter.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
    }

    ke.ipl.lower(ipl);
}

pub fn broadcast(func: *const fn (u32, ?*anyopaque) void, arg: ?*anyopaque) void {
    const ipl = ke.ipl.raise(.High);
    const curcpu = percpu.local();

    curcpu.func = func;
    curcpu.arg = arg;
    curcpu.counter = .init(@truncate(ke.ncpus - 1));

    for (0..ke.ncpus) |i| {
        if (i == ke.cpu.current()) continue;
        const remote = percpu.remote(@intCast(i));

        remote.pending.set(ke.cpu.current(), .monotonic);

        const state = remote.state.swap(.Pending, .release);

        if (state == .Idle) {
            pl.send_ipi(@intCast(i));
        }
    }

    while (curcpu.counter.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
    }

    ke.ipl.lower(ipl);
}

pub fn ipi_handler() void {
    const curcpu = percpu.local();

    while (true) {
        // Mark the current CPU as processing IPIs, if the CAS fails here,
        // then it's probably some kind of IPI that was sent to force us to
        // check software interrupts (like a rescheduling IPI).
        const val = curcpu.state.cmpxchgStrong(
            .Pending,
            .Running,
            .acquire,
            .monotonic,
        );

        if (val != null) {
            // CAS failed.
            return;
        }

        const words = curcpu.pending.storage.len;

        for (0..words) |i| {
            var word = curcpu.pending.storage[i].swap(0, .monotonic);

            // Go through every CPU in our pending mask.
            while (word != 0) {
                const bit = @ctz(word);
                const cpu = @bitSizeOf(usize) * i + bit;

                // Call its function and decrement the counter.
                const remote = percpu.remote(@intCast(cpu));
                remote.func(@intCast(cpu), remote.arg);

                // Ensure all previous memory operations complete.
                _ = remote.counter.fetchSub(1, .release);

                word &= (word - 1);
            }
        }

        // Try to make the CPU state go from running to idle, if this fails
        // then we still have work to do.
        _ = curcpu.state.cmpxchgStrong(
            .Running,
            .Idle,
            .monotonic,
            .monotonic,
        ) orelse return;
    }
}
