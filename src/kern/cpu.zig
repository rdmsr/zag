const std = @import("std");
const rtl = @import("rtl");
const b = @import("base");
const config = @import("config");
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

/// Bitmask of CPUs.
pub const CpuMask = struct {
    const bits_per_word = @sizeOf(usize) * 8;
    const num_words = (config.CONFIG_NCPUS + bits_per_word - 1) / bits_per_word;

    bits: [num_words]usize,

    /// Return an empty `CpuMask`.
    pub fn empty() CpuMask {
        return CpuMask{ .bits = [_]usize{0} ** num_words };
    }

    /// Set the bit corresponding to `cpu_id`.
    pub fn set(self: *CpuMask, cpu_id: usize) void {
        const word_index = cpu_id / bits_per_word;
        const bit_index = cpu_id % bits_per_word;
        self.bits[word_index] |= (@as(usize, 1) << @intCast(bit_index));
    }

    /// Clear the bit corresponding to `cpu_id`.
    pub fn clear(self: *CpuMask, cpu_id: usize) void {
        const word_index = cpu_id / bits_per_word;
        const bit_index = cpu_id % bits_per_word;
        self.bits[word_index] &= ~(@as(usize, 1) << @intCast(bit_index));
    }

    /// Check whether the bit corresponding to `cpu_id` is set.
    pub fn is_set(self: *const CpuMask, cpu_id: usize) bool {
        const word_index = cpu_id / bits_per_word;
        const bit_index = cpu_id % bits_per_word;
        return (self.bits[word_index] & (@as(usize, 1) << @intCast(bit_index))) != 0;
    }

    pub fn is_full(self: *const CpuMask) bool {
        for (self.bits) |word| {
            if (word != std.math.maxInt(usize)) return false;
        }
        return true;
    }
};
