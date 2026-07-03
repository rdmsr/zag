const config = @import("config");
const init_mod = @import("init.zig");
const r = @import("root");
const rtl = @import("rtl");

pub const impl = switch (config.arch) {
    .amd64 => @import("amd64/impl.zig"),
    else => @compileError("unsupported architecture"),
};

const ImplSchema = struct {
    pub const ThreadContext = struct {};

    /// Maximum number of pages that can be flushed by individual TLB flushes
    /// before it is more efficient to flush the entire TLB.
    pub const tlb_max_pages = 0;

    /// Set the hardware interrupt priority level.
    pub fn set_hardware_ipl(level: ipl.Ipl) void {
        _ = level;
    }

    /// Read a per-cpu pointer on another CPU.
    pub fn percpu_ptr_other(variable: anytype, id: u32) @TypeOf(variable) {
        _ = id;
    }

    /// Read a per-cpu pointer on the current CPU.
    pub fn percpu_ptr(variable: anytype) @TypeOf(variable) {}

    /// Send a rescheduling inter-processor interrupt (IPI)
    /// on the target CPU.
    pub fn send_resched_ipi(target: u32) void {
        _ = target;
    }

    /// Send a TLB shootdown IPI on the target CPU.
    pub fn send_tlb_ipi(target: u32) void {
        _ = target;
    }

    /// Flush the entire TLB on the current CPU.
    pub fn flush_full_tlb() void {}

    /// Flush the TLB entry matching `va` on the current CPU.
    pub fn flush_tlb(va: r.VAddr) void {
        _ = va;
    }

    /// Enable interrupts.
    pub fn enable_interrupts() void {}

    /// Disable interrupts.
    /// Return the previous interrupt state.
    pub fn disable_interrupts() bool {
        return false;
    }

    /// Restore the state of interrupts.
    pub fn restore_interrupts(state: bool) void {
        _ = state;
    }

    /// Implementation-defined early initialization.
    pub fn early_init() void {}
};

comptime {
    rtl.assert_interface(impl, ImplSchema);
}

pub const init = init_mod.init;

// === Exported Modules ===
pub const ipl = @import("ipl.zig");
pub const panic = @import("panic.zig");
pub const spinlock = @import("spinlock.zig");
pub const log = @import("log.zig");
pub const cpu = @import("cpu.zig");
pub const thread = @import("thread.zig");
pub const dpc = @import("dpc.zig");
pub const time = @import("time.zig");
pub const sched = @import("sched.zig");
pub const wait = @import("wait.zig");
pub const timer = @import("timer.zig");
pub const log_ring = @import("log_ring.zig");
pub const event = @import("event.zig");
pub const turnstile = @import("turnstile.zig");
pub const mutex = @import("mutex.zig");
pub const queue = @import("queue.zig");
pub const shootdown = @import("shootdown.zig");
