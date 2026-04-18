const b = @import("root");
const std = @import("std");
const acpi = b.pl.acpi;
const ke = b.ke;
const arch = @import("arch");

var pm_timer: ke.ClockSource = .{
    .name = "ACPI",
    .quality = 25,
    .frequency = 3579545, // 3.579545 MHz
    .read_count = read_timer,
    .mask = std.math.maxInt(u24),
    .p = 0,
    .n = 0,
};

var timer_gas: acpi.Gas = undefined;

pub fn init(fadt: *acpi.Fadt) linksection(b.init) void {
    const fadt_rev = fadt.revision();

    if (fadt.pm_tmr_len == 0 or fadt.pm_tmr_blk == 0) {
        return;
    }

    if (fadt_rev >= 2 and fadt.x_pm_tmr_blk.address == 0) {
        return;
    }

    if (ke.clock.is_better_than(&pm_timer)) return;

    timer_gas.address_space_id = .SystemIo;
    timer_gas.address = fadt.pm_tmr_blk;
    timer_gas.access_size = 3;
    timer_gas.register_bit_width = 32;
    timer_gas.register_bit_offset = 0;

    if (fadt_rev >= 2) {
        timer_gas = fadt.x_pm_tmr_blk;
    }

    if (timer_gas.access_size == 0) {
        timer_gas.access_size = 3;
    }

    // Indicates whether the timer is 32-bit
    if (fadt.flags & (1 << 8) != 0) {
        pm_timer.mask = std.math.maxInt(u32);
    }

    ke.clock.register_source(&pm_timer);
}

fn read_timer() u64 {
    return timer_gas.read();
}
