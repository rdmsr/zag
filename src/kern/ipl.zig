const std = @import("std");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

/// Interrupt priority level (IPL)
pub const Ipl = enum(u8) {
    /// All interrupts enabled.
    Passive = 0,
    /// Preemption disabled.
    Dispatch = 1,
    /// Device interrupts disabled.
    Device = 13,
    /// All interrupts disabled.
    High = 15,

    pub fn get_max_software() Ipl {
        return .Dispatch;
    }
};

const PerCpu = struct {
    /// Current IPL on this CPU.
    ipl: Ipl,
    /// Bitmask of pending software interrupts on this CPU.
    pending_softints: std.atomic.Value(u8),
};

pub const percpu = ke.CpuLocal(PerCpu, .{
    .ipl = .Passive,
    .pending_softints = std.atomic.Value(u8).init(0),
});

pub fn current() Ipl {
    return percpu.local().ipl;
}

/// Raise IPL to `new`.
/// Panics if the current IPL is higher than requested.
pub fn raise(new: Ipl) Ipl {
    const ints = ki.impl.disable_interrupts();

    var cpu = percpu.local();
    const old = cpu.ipl;

    if (@intFromEnum(new) < @intFromEnum(old)) {
        std.debug.panic("ke.ipl.raise(): Target IPL ({}) is lower than current IPL ({})", .{ new, old });
    }

    if (@intFromEnum(new) > @intFromEnum(Ipl.get_max_software())) {
        ki.impl.set_hardware_ipl(new);
    }

    cpu.ipl = new;

    ki.impl.restore_interrupts(ints);

    return old;
}

/// Lower IPL to `new`.
/// Panics if the current IPL is lower than requested.
pub fn lower(new: Ipl) void {
    const ints = ki.impl.disable_interrupts();
    var cpu = percpu.local();
    const cpu_id = ke.cpu.current();
    const old = cpu.ipl;

    if (@intFromEnum(new) > @intFromEnum(old)) {
        std.debug.panic("ke.ipl.lower(): Target IPL ({}) is higher than current IPL ({})", .{ new, old });
    }

    if (@intFromEnum(new) <= @intFromEnum(Ipl.get_max_software()) and @intFromEnum(old) > @intFromEnum(Ipl.get_max_software())) {
        ki.impl.set_hardware_ipl(.Passive);
    }

    cpu.ipl = new;

    ki.impl.restore_interrupts(ints);

    if (@intFromEnum(new) < @intFromEnum(Ipl.Dispatch) and is_softint_pending(.Dispatch)) {
        ki.dpc.dispatch(cpu_id);
    }
}

comptime {
    if (!@hasDecl(ki.impl, "set_hardware_ipl")) @compileError("impl must provide set_hardware_ipl()");
}

/// Set the hardware IPL to `new`.
pub fn set_hardware(new: Ipl) Ipl {
    var cpu = percpu.local();
    const old = cpu.ipl;

    cpu.ipl = new;

    ki.impl.set_hardware_ipl(new);

    return old;
}

/// Mark a software interrupt of IPL `ipl` on `cpu` as pending.
pub fn set_softint_pending(cpu: u32, ipl: Ipl) void {
    std.debug.assert(@intFromEnum(ipl) <= @intFromEnum(Ipl.Dispatch));
    _ = percpu.remote(cpu).pending_softints.bitSet(@intCast(@intFromEnum(ipl)), .monotonic);
}

/// Mark a software interrupt of IPL `ipl` on `cpu` as handled.
pub fn clear_softint_pending(cpu: u32, ipl: Ipl) void {
    std.debug.assert(@intFromEnum(ipl) <= @intFromEnum(Ipl.Dispatch));
    _ = percpu.remote(cpu).pending_softints.bitReset(@intCast(@intFromEnum(ipl)), .monotonic);
}

/// Check whether a software interrupt of IPL `ipl` on the current CPU is pending.
pub fn is_softint_pending(ipl: Ipl) bool {
    std.debug.assert(@intFromEnum(ipl) <= @intFromEnum(Ipl.Dispatch));
    const shift: u3 = @intCast(@intFromEnum(ipl));
    const bit: u8 = @as(u8, 1) << shift;
    return percpu.local().pending_softints.load(.monotonic) & bit != 0;
}
