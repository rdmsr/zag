const config = @import("config");

// === Exported Modules ===
pub const private = @import("private.zig");

const p = private;

// === Exported types ===
pub const Ipl = p.ipl.Ipl;
pub const SpinLock = p.spinlock.SpinLock;
pub const Thread = p.thread.Thread;
pub const Dpc = p.dpc.Dpc;
pub const TimeCounter = p.time.TimeCounter;
pub const Timer = p.timer.Timer;
pub const Console = p.log.Console;
pub const CpuLocal = p.cpu.CpuLocal;
pub const CpuMask = p.cpu.CpuMask;

// === Exported Interfaces ===
pub const panic = p.panic.panic;

pub const ipl = struct {
    pub const raise = p.ipl.raise;
    pub const lower = p.ipl.lower;
    pub const set_hardware = p.ipl.set_hardware;
    pub const current = p.ipl.current;
};

pub const thread = struct {
    pub const init = p.thread.init;
};

pub const dpc = struct {
    pub const enqueue = p.dpc.enqueue;
};

pub const time = struct {
    pub const register_source = p.time.register_source;
    pub const read_time_nano = p.time.read_time_nano;
    pub const best = p.time.best;
    pub const sleep = p.time.sleep;
};

pub const sched = struct {
    pub const enqueue = p.sched.enqueue;
    pub const block = p.sched.block;
    pub const unblock = p.sched.unblock;
    pub const late_init = p.sched.late_init;
};

pub const timer = struct {
    pub const set = p.timer.set;
    pub const cancel = p.timer.cancel;
};

pub const wait = struct {
    pub const wait_one = p.wait.wait_one;
    pub const wait_any = p.wait.wait_any;
};

pub const log = struct {
    pub const register_console = p.log.register_console;
    pub const log = p.log.log;
};

pub const cpu = struct {
    pub const current = p.cpu.current;
};

/// Number of CPUs on the system
pub var ncpus: usize = 0;
