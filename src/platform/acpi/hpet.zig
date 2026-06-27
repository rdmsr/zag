const r = @import("root");
const std = @import("std");
const acpi = r.pl.acpi;
const mm = r.mm;
const ke = r.ke;

var hpet_timer: ke.TimeCounter = .{
    .name = "HPET",
    .quality = 50,
    .frequency = 0, // Filled at runtime
    .read_count = read_hpet,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

var hpet_regs: *volatile acpi.HpetRegs = undefined;

const femtos_per_s = 1_000_000_000_000_000;

pub fn init(hpet: *acpi.HpetTable) linksection(r.init) void {
    hpet_regs = @ptrFromInt(mm.p2v(hpet.base_address.address));

    hpet_timer.frequency = femtos_per_s / (r.mmio_read(u64, @intFromPtr(&hpet_regs.general_capabilities)) >> 32);

    // Disable timer.
    r.mmio_write(u64, @intFromPtr(&hpet_regs.general_configuration), 0);

    // Reset counter.
    r.mmio_write(u64, @intFromPtr(&hpet_regs.main_counter_value), 0);

    // Enable timer.
    r.mmio_write(u64, @intFromPtr(&hpet_regs.general_configuration), 1);

    ke.time.register_source(&hpet_timer);
}

fn read_hpet() u64 {
    return r.mmio_read(u64, @intFromPtr(&hpet_regs.main_counter_value));
}
