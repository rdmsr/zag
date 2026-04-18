const r = @import("root");
const pl = r.pl;
const amd64 = r.arch;
const std = @import("std");
const tsc = @import("tsc.zig");
const pvclock = @import("pvclock.zig");
const apic = @import("apic.zig");
const smp = @import("smp.zig");

const ki = r.ke.private;

pub const name = "PC";

const com1 = 0x3F8;

const log = std.log.scoped(.@"amd64/pc");

fn com1_init() linksection(r.init) void {
    amd64.outb(com1 + 0x3, 0x80);
    amd64.outb(com1 + 0x0, 0x0c);
    amd64.outb(com1 + 0x1, 0x00);
    amd64.outb(com1 + 0x3, 0x03);
    amd64.outb(com1 + 0x2, 0xc7);
    amd64.outb(com1 + 0x4, 0x00);
}

fn com1_write(c: u8) void {
    while ((amd64.inb(com1 + 0x5) & 0x20) == 0) {}
    if (c == '\n') {
        amd64.outb(com1, '\r');
    }
    amd64.outb(com1, c);
}

pub fn early_init(boot_info: *pl.BootInfo) linksection(r.init) void {
    com1_init();

    const f = amd64.cpu_features;

    log.info("CPU: {s}", .{&f.brand_string});
    log.info("vendor={s} family={x} features={}{}{}{}{}{}{}{}{}{}{}{}", .{
        @tagName(f.vendor),
        f.family,
        @intFromBool(f.x2apic),
        @intFromBool(f.five_level_paging),
        @intFromBool(f.nx),
        @intFromBool(f.pcid),
        @intFromBool(f.pge),
        @intFromBool(f.smap),
        @intFromBool(f.smep),
        @intFromBool(f.gib_pages),
        @intFromBool(f.invariant_tsc),
        @intFromBool(f.xsave),
        @intFromBool(f.fxsave),
        @intFromBool(f.tsc_deadline),
    });

    if (amd64.hypervisor.info) |h| {
        log.info("running on hypervisor {s}", .{@tagName(h.vendor)});
    }
    _ = boot_info;
}

fn init_hypervisor(hv: amd64.hypervisor.Info) void {
    switch (hv.data) {
        .KVM => |kvm_info| {
            if (kvm_info.features.clocksource2 == true) {
                pvclock.init();
            }
        },
        else => {},
    }
}

pub fn init_ap() void {
    if (amd64.cpu_features.x2apic) {
        apic.enter_x2apic();
    }
    apic.init_local();
}

pub fn late_init(boot_info: *pl.BootInfo) linksection(r.init) void {
    pl.acpi.init(boot_info);

    if (amd64.hypervisor.info) |hv| {
        init_hypervisor(hv);
    }

    tsc.init();
    apic.init();

    if (apic.apics.items.len != 0) {
        smp.init();
    }

    if (amd64.cpu_features.x2apic) {
        apic.enter_x2apic();
    }
}

pub fn debug_write(c: u8) void {
    com1_write(c);
}

pub fn arm_timer(_: u64) void {}
