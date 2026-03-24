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

/// Bitmask of pending software interrupts on this CPU.
const pending_softints = ke.CpuLocal(std.atomic.Value(u8), .init(0));

/// Raise IPL to `new`.
/// Panics if the current IPL is higher than requested.
pub fn raise(new: Ipl) Ipl {
    const ints = ki.impl.disable_interrupts();

    var cpu = ke.curcpu();
    const old = cpu.ipl;

    if (@intFromEnum(new) < @intFromEnum(old)) {
        ke.panic("ke.ipl.raise(): Target IPL ({}) is lower than current IPL ({})\n", .{ new, old });
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
    var cpu = ke.curcpu();
    const old = cpu.ipl;

    if (@intFromEnum(new) > @intFromEnum(old)) {
        ke.panic("ke.ipl.lower(): Target IPL ({}) is higher than current IPL ({})\n", .{ new, old });
    }

    if (@intFromEnum(new) <= @intFromEnum(Ipl.get_max_software()) and @intFromEnum(old) > @intFromEnum(Ipl.get_max_software())) {
        ki.impl.set_hardware_ipl(.Passive);
    }

    cpu.ipl = new;

    ki.impl.restore_interrupts(ints);

    if (@intFromEnum(new) < @intFromEnum(Ipl.Dispatch) and is_softint_pending(.Dispatch)) {
        ki.dpc.dispatch(cpu);
    }
}

comptime {
    if (!@hasDecl(ki.impl, "set_hardware_ipl")) @compileError("impl must provide set_hardware_ipl()");
}

/// Set the hardware IPL to `new`.
pub fn set_hardware(new: Ipl) Ipl {
    var cpu = ke.curcpu();
    const old = cpu.ipl;

    cpu.ipl = new;

    ki.impl.set_hardware_ipl(new);

    return old;
}

/// Mark a software interrupt of IPL `ipl` on `cpu` as pending.
pub fn set_softint_pending(cpu: *ke.Cpu, ipl: Ipl) void {
    std.debug.assert(@intFromEnum(ipl) <= @intFromEnum(Ipl.Dispatch));
    _ = pending_softints.remote(cpu).bitSet(@intCast(@intFromEnum(ipl)), .monotonic);
}

/// Mark a software interrupt of IPL `ipl` on `cpu` as handled.
pub fn clear_softint_pending(cpu: *ke.Cpu, ipl: Ipl) void {
    std.debug.assert(@intFromEnum(ipl) <= @intFromEnum(Ipl.Dispatch));
    _ = pending_softints.remote(cpu).bitReset(@intCast(@intFromEnum(ipl)), .monotonic);
}

/// Check whether a software interrupt of IPL `ipl` on the current CPU is pending.
pub fn is_softint_pending(ipl: Ipl) bool {
    std.debug.assert(@intFromEnum(ipl) <= @intFromEnum(Ipl.Dispatch));
    const shift: u3 = @intCast(@intFromEnum(ipl));
    const bit: u8 = @as(u8, 1) << shift;
    return pending_softints.local().load(.monotonic) & bit != 0;
}
