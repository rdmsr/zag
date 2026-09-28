const r = @import("root");
const ke = r.ke;
const std = @import("std");

export fn riscv_trap_handler(cause: usize, pc: usize) callconv(.c) void {
    if (cause == ((@as(usize, 1) << 63) | 5)) {
        const old = ke.ipl.set_hardware(.Device);
        ke.private.timer.clock();
        _ = ke.ipl.set_hardware(old);
        if (old == .Passive and ke.private.ipl.is_softint_pending(.Dispatch)) {
            ke.private.dpc.dispatch();
        }
        return;
    }
    std.debug.panic("trap: cause = 0x{x}, pc = 0x{x}, tval = 0x{x}", .{ cause, pc, rv64.read_csr("stval") });
}
