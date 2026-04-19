const std = @import("std");
const amd64 = @import("arch");
const r = @import("root");
const tsc = @import("tsc.zig");
const acpi = r.pl.acpi;
const mm = r.mm;
const ke = r.ke;

const MadtLapic = extern struct {
    header: acpi.MadtEntryHeader,
    id: u8 align(1),
    version: u8 align(1),
    flags: u32 align(1),
};

const MadtIoapic = extern struct {
    header: acpi.MadtEntryHeader,
    id: u8 align(1),
    version: u8 align(1),
    flags: u32 align(1),
    address: u32 align(1),
    global_system_interrupt_base: u32 align(1),
};

const MadtIso = extern struct {
    header: acpi.MadtEntryHeader,
    bus_source: u8 align(1),
    irq_source: u8 align(1),
    global_system_interrupt: u32 align(1),
    flags: u16 align(1),
};

const MadtX2Lapic = extern struct {
    header: acpi.MadtEntryHeader,
    reserved: u16 align(1),
    id: u32 align(1),
    flags: u32 align(1),
    acpi_uid: u32 align(1),
};

pub const ApicRegisters = enum(u32) {
    Id = 0x20,
    Version = 0x30,

    Tpr = 0x80,
    Apr = 0x90,
    Ppr = 0xA0,
    Eoi = 0xB0,
    RemoteRead = 0xC0,
    Ldr = 0xD0,
    Dfr = 0xE0,
    Svr = 0xF0,

    Isr = 0x100,
    Tmr = 0x180,
    Irr = 0x200,
    Esr = 0x280,

    LvtCmci = 0x2F0,
    Icr = 0x300,
    Icr1 = 0x310,
    LvtTimer = 0x320,
    LvtThermal = 0x330,
    LvtPerf = 0x340,
    LvtLint0 = 0x350,
    LvtLint1 = 0x360,
    LvtError = 0x370,

    TimerInitialCount = 0x380,
    TimerCurrentCount = 0x390,
    TimerDivideConfig = 0x3E0,
};

pub var apics: std.ArrayList(u32) = .empty;
var xapic_address: ?usize = null;
pub var xapic_base_physical: usize = 0;
const in_x2apic_mode = ke.CpuLocal(bool, false);
const timer_ticks_per_us = ke.CpuLocal(u64, 0);

const log = std.log.scoped(.apic);

fn xapic_write(register: ApicRegisters, value: u32) void {
    const lapic_base = xapic_address orelse return;
    r.mmio_write(u32, lapic_base + @intFromEnum(register), value);
}

fn xapic_read(register: ApicRegisters) u32 {
    const lapic_base = xapic_address orelse return 0;
    return r.mmio_read(u32, lapic_base + @intFromEnum(register));
}

fn x2apic_write(register: ApicRegisters, value: u64) void {
    amd64.wrmsr(@intFromEnum(amd64.Msr.X2ApicBase) + (@as(u32, @intFromEnum(register)) >> 4), value);
}

fn x2apic_read(register: ApicRegisters) u64 {
    return amd64.rdmsr(@intFromEnum(amd64.Msr.X2ApicBase) + (@as(u32, @intFromEnum(register)) >> 4));
}

pub fn write(register: ApicRegisters, value: u32) void {
    if (in_x2apic_mode.local().*) {
        x2apic_write(register, value);
    } else {
        xapic_write(register, value);
    }
}

pub fn read(register: ApicRegisters) u64 {
    if (in_x2apic_mode.local().*) {
        return x2apic_read(register);
    } else {
        return @intCast(xapic_read(register));
    }
}

pub fn get_id() u32 {
    if (in_x2apic_mode.local().*) {
        return @truncate(x2apic_read(.Id));
    } else {
        return xapic_read(.Id) >> 24;
    }
}

pub fn send_init(apic_id: u32) void {
    if (in_x2apic_mode.local().*) {
        x2apic_write(.Icr, (@as(u64, apic_id) << 32) | 0x0000C500);
    } else {
        xapic_write(.Icr1, @as(u32, apic_id) << 24);
        xapic_write(.Icr, 0x0000C500);
        while (xapic_read(.Icr) & (1 << 12) != 0) {}
    }
}

pub fn send_sipi(apic_id: u32, startup_page: u8) void {
    if (in_x2apic_mode.local().*) {
        x2apic_write(.Icr, (@as(u64, apic_id) << 32) | 0x00004600 | startup_page);
    } else {
        xapic_write(.Icr1, @as(u32, apic_id) << 24);
        xapic_write(.Icr, @as(u32, 0x00004600) | startup_page);
        while (xapic_read(.Icr) & (1 << 12) != 0) {}
    }
}

pub fn send_ipi(apic_id: u32, vector: u8, delivery_mode: u8) void {
    if (in_x2apic_mode.local().*) {
        const icr_value = (@as(u64, apic_id) << 32) | (@as(u64, delivery_mode) << 8) | vector;
        x2apic_write(.Icr, icr_value);
    } else {
        const icr_value = (@as(u32, delivery_mode) << 8) | vector;
        // Write to ICR1 first, because writing to the low word causes
        // the IPI to be sent.
        xapic_write(.Icr1, @as(u32, apic_id) << 24);
        xapic_write(.Icr, @intCast(icr_value));

        // Wait for the delivery status bit to clear.
        while (xapic_read(.Icr) & (1 << 12) != 0) {}
    }
}

fn lapic_calibrate(ms: u64) u64 {
    write(.LvtTimer, (1 << 16));
    write(.TimerInitialCount, std.math.maxInt(u32));

    ke.clock.sleep(std.time.ns_per_ms * ms);

    const ticks = std.math.maxInt(u32) - read(.TimerCurrentCount);

    write(.LvtTimer, (1 << 16));
    write(.TimerInitialCount, 0);

    return ticks;
}

fn timer_init() linksection(r.init) void {
    if (amd64.cpu_features.tsc_deadline) {
        // TSC-deadline mode.
        write(.LvtTimer, 32 | (2 << 17));
        asm volatile ("mfence" ::: .{ .memory = true });
        return;
    }

    // Divide by 16.
    write(.TimerDivideConfig, 0x3);

    const runs = 5;
    const calib_ms = 10;
    var total_ticks: u64 = 0;

    for (0..runs) |_| {
        total_ticks += lapic_calibrate(calib_ms);
    }

    const avg_ticks = total_ticks / runs;
    const calib_us = calib_ms * std.time.us_per_ms;

    timer_ticks_per_us.local().* = (avg_ticks / calib_us);
}

pub fn arm_timer(ns: r.Nanoseconds) void {
    if (amd64.cpu_features.tsc_deadline) {
        const now = amd64.rdtsc();
        const deadline = now + (ns * tsc.tsc.frequency / std.time.ns_per_s);
        amd64.write_msr(.TscDeadline, deadline);
        return;
    }

    // Masked.
    write(.LvtTimer, 1 << 16);
    write(.TimerInitialCount, 0);

    const us = ns / std.time.ns_per_us;
    const ticks: u32 = @truncate(@max(us * timer_ticks_per_us.local().*, 1));

    // Setup IRQ.
    write(.LvtTimer, 32);

    // Divide by 16
    write(.TimerDivideConfig, 0x3);
    write(.TimerInitialCount, @as(u32, ticks));
}

pub fn stop_timer() void {
    if (amd64.cpu_features.tsc_deadline) {
        amd64.write_msr(.TscDeadline, 0);
        return;
    }

    write(.LvtTimer, (1 << 16));
    write(.TimerInitialCount, 0);
}

pub fn eoi() void {
    write(.Eoi, 0);
}

pub fn init() linksection(r.init) void {
    var iter = acpi.madt.iterator();

    const cur_cpu_id = get_id();

    // First, we iterate to check if we find *any* APICs. If we do, then we must use them over x2APIC entries for IDs under 255.
    var has_lapics = false;
    while (iter.next()) |entry| {
        switch (entry.type) {
            .LocalApic => {
                const lapic: *const MadtLapic = @ptrCast(entry);
                if (lapic.flags & 1 == 0 or lapic.id == cur_cpu_id) continue;
                has_lapics = true;
                break;
            },
            else => {},
        }
    }

    // Now, actually iterate and add the APIC IDs to the list.
    iter = acpi.madt.iterator();

    while (iter.next()) |entry| {
        switch (entry.type) {
            .LocalApic => {
                const lapic: *const MadtLapic = @ptrCast(entry);
                if (lapic.flags & 1 == 0 or lapic.id == cur_cpu_id) continue;
                apics.append(mm.zone.gpa, lapic.id) catch @panic("Could not append APIC ID to list");
            },
            .X2LocalApic => {
                const x2lapic: *const MadtX2Lapic = @ptrCast(entry);
                if (has_lapics and x2lapic.id <= 0xFF) continue;
                if (x2lapic.flags & 1 == 0 or x2lapic.id == cur_cpu_id) continue;
                apics.append(mm.zone.gpa, x2lapic.id) catch @panic("Could not append APIC ID to list");
            },
            else => {},
        }
    }

    // If in xapic mode, set the xapic base address.
    const base = amd64.read_msr(.LapicBase);

    if (base & (1 << 10) == 0) {
        xapic_address = mm.p2v(base & 0xFFFFF000);
        xapic_base_physical = base & 0xFFFFF000;
    } else {
        in_x2apic_mode.local().* = true;
    }

    init_local();
}

pub fn init_local() void {
    write(.Svr, @intCast(read(.Svr) | 0x1FF));
    write(.Tpr, 0);
    write(.Eoi, 0);
    timer_init();
}

pub fn enter_x2apic() void {
    const apic_base = amd64.read_msr(.LapicBase);
    in_x2apic_mode.local().* = true;
    if (apic_base & (1 << 10) != 0) return; // Already in x2apic.
    if (apic_base & (1 << 11) == 0) {
        // Ensure xAPIC is enabled first.
        amd64.write_msr(.LapicBase, apic_base | (1 << 11));
    }
    amd64.write_msr(.LapicBase, apic_base | (1 << 10) | (1 << 11));
}
