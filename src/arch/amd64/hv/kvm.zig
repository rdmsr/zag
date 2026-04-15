//! KVM paravirtualization support.
const std = @import("std");
const amd64 = @import("../root.zig");

pub const Features = packed struct(u32) {
    clocksource: bool,
    nop_io_delay: bool,
    mmu_op: bool,
    clocksource2: bool,
    async_pf: bool,
    steal_time: bool,
    pv_eoi: bool,
    pv_unhalt: bool,
    _reserved0: u1,
    pv_tlb_flush: bool,
    async_pf_vmexit: bool,
    pv_send_ipi: bool,
    pv_poll_control: bool,
    pv_sched_yield: bool,
    async_pf_int: bool,
    msi_ext_dest_id: bool,
    hc_map_gpa_range: bool,
    migration_control: bool,
    _reserved1: u14,
};

pub const Info = struct {
    features: Features,
};

const Msr = enum(u32) {
    SystemTime = 0x4B564D01,
    WallClock = 0x4B564D00,
    AsyncPf = 0x4B564D02,
    AsyncPfEn = 0x4B564D03,
    StealTime = 0x4B564D04,
    PvEoi = 0x4B564D05,
    AsyncPfInt = 0x4B564D06,
    _,
};

fn read_msr(msr: Msr) u64 {
    return amd64.rdmsr(@intFromEnum(msr));
}

fn write_msr(msr: Msr, value: u64) void {
    amd64.wrmsr(@intFromEnum(msr), value);
}

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

pub const PVClockSource = struct {
    page: *volatile PVClock,
    time_at_boot: u64,

    pub fn read(self: *PVClockSource) u64 {
        while (true) {
            const ver = @atomicLoad(u32, &self.page.version, .acquire);
            if (ver & 1 != 0) continue;

            const tsc_shift = self.page.tsc_shift;
            const tsc_delta = amd64.rdtsc() - self.page.tsc_timestamp;
            const shifted = if (tsc_shift >= 0)
                tsc_delta << @intCast(tsc_shift)
            else
                tsc_delta >> @intCast(-tsc_shift);
            const ns = self.page.system_time +
                (shifted * @as(u128, self.page.tsc_to_system_mul) >> 32);

            if (@atomicLoad(u32, &self.page.version, .acquire) == ver)
                return @as(u64, @truncate(ns)) - self.time_at_boot;
        }
    }

    pub fn init(phys_page: usize, virt_page: usize) PVClockSource {
        const page: *volatile PVClock = @ptrFromInt(virt_page);
        write_msr(.SystemTime, phys_page | 1);
        var src = PVClockSource{ .page = page, .time_at_boot = 0 };
        src.time_at_boot = src.read();
        return src;
    }
};

pub fn detect(highest_function: u32) Info {
    if (highest_function < 0x40000001) {
        return .{ .features = @bitCast(@as(u32, 0)) };
    }

    const r = amd64.cpuid(0x40000001, 0);
    return Info{
        .features = @bitCast(r.eax),
    };
}
