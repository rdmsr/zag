const config = @import("config");

// === Exported Modules ===
pub const private = @import("private.zig");

const p = private;

// === Exported types ===
pub const Ipl = p.ipl.Ipl;
pub const SpinLock = p.spinlock.SpinLock;
pub const Thread = p.thread.Thread;
pub const Dpc = p.dpc.Dpc;
pub const TimeCounter = p.timecounter.TimeCounter;
pub const Timer = p.timer.Timer;

// === Exported Interfaces ===
pub const log = p.log.log;
pub const panic = p.panic.panic;

pub const ipl = struct {
    pub const raise = p.ipl.raise;
    pub const lower = p.ipl.lower;
    pub const set_hardware = p.ipl.set_hardware;
};

pub const thread = struct {
    pub const init = p.thread.init;
};

pub const dpc = struct {
    pub const enqueue = p.dpc.enqueue;
};

pub const timecounter = struct {
    pub const register = p.timecounter.register;
    pub const read_time_nano = p.timecounter.read_time_nano;
};

pub const sched = struct {
    pub const enqueue = p.sched.enqueue;
    pub const block = p.sched.block;
    pub const unblock = p.sched.unblock;
};

pub const timer = struct {
    pub const set = p.timer.set;
    pub const cancel = p.timer.cancel;
};

pub const wait = struct {
    pub const wait_one = p.wait.wait_one;
    pub const wait_any = p.wait.wait_any;
};

pub const Cpu = p.cpu.Cpu;
pub const CpuLocal = p.cpu.CpuLocal;
pub const CpuMask = p.cpu.CpuMask;

comptime {
    if (!@hasDecl(p.impl, "curcpu")) @compileError("impl must provide curcpu()");
}

/// Return the current CPU
pub const curcpu: fn () *Cpu = p.impl.curcpu;

/// Number of CPUs on the system
pub var ncpus: usize = 0;

/// Array of CPUs
pub var cpus: []*Cpu = undefined;
