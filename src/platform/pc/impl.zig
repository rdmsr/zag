const b = @import("base");
const pl = b.pl;
const amd64 = b.arch;
const std = @import("std");
const tsc = @import("tsc.zig");
const pvclock = @import("pvclock.zig");

const ki = b.ke.private;

pub const name = "PC";

const com1 = 0x3F8;

fn com1_init() linksection(b.init) void {
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

pub fn early_init(boot_info: *pl.BootInfo) linksection(b.init) void {
    com1_init();

    amd64.detect_cpu_features();

    const f = amd64.cpu_features;

    std.log.info("amd64/cpu: {s}", .{&f.brand_string});
    std.log.info("amd64/cpu: vendor={s} features={}{}{}{}{}{}{}{}{}{}{}{}", .{
        &f.vendor_string,
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

    if (amd64.hypervisor_info) |h| {
        std.log.info("amd64/cpu: running on hypervisor {s}", .{@tagName(h.vendor)});
    }
    _ = boot_info;
}

pub fn late_init(boot_info: *pl.BootInfo) linksection(b.init) void {
    pl.acpi.init(boot_info);

pub fn devices_init() void {}

pub fn debug_write(c: u8) void {
    com1_write(c);
}

pub fn arm_timer(_: u64) void {}
