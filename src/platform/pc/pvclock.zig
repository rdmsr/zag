const amd64 = @import("arch");
const b = @import("base");
const std = @import("std");
const mm = b.mm;
const ke = b.ke;

const PVClock = extern struct {
    version: u32,
    pad0: u32,
    tsc_timestamp: u64,
    system_time: u64,
    tsc_to_system_mul: u32,
    tsc_shift: i8,
    flags: u8,
    pad1: [2]u8,
};

var pvclock: *PVClock = undefined;

var pvclock_tc: ke.TimeCounter = .{
    .name = "pvclock",
    .quality = 75,
    .frequency = std.time.ns_per_s,
    .read_count = read_pvclock,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

var time_at_boot: u64 = 0;

pub fn init() linksection(b.init) void {
    const page = mm.phys.alloc();
    pvclock = @ptrFromInt(mm.p2v(page));

    amd64.wrmsr(.KvmSystemTimeNew, page | 1);

    time_at_boot = read_pvclock();

    ke.time.register_source(&pvclock_tc);
}

fn read_pvclock() u64 {
    while (true) {
        const ver = b.mmio_read(u32, @intFromPtr(&pvclock.version));
        if (ver & 1 != 0) continue; // Update in progress.

        const tsc_shift = b.mmio_read(i8, @intFromPtr(&pvclock.tsc_shift));

        const tsc_delta = amd64.rdtsc() - b.mmio_read(u64, @intFromPtr(&pvclock.tsc_timestamp));
        const shifted = if (tsc_shift >= 0)
            tsc_delta << @intCast(tsc_shift)
        else
            tsc_delta >> @intCast(-tsc_shift);

        const ns = b.mmio_read(u64, @intFromPtr(&pvclock.system_time)) +
            (shifted * @as(u128, b.mmio_read(u32, @intFromPtr(&pvclock.tsc_to_system_mul))) >> 32);

        if (b.mmio_read(u32, @intFromPtr(&pvclock.version)) == ver) return @as(u64, @truncate(ns)) - time_at_boot;
    }
}
