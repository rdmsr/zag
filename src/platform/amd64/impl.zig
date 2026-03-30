const b = @import("base");
pub const cpu = @import("cpu.zig");
const ki = b.ke.private;
const std = @import("std");

pub const name = "amd64";

const com1 = 0x3F8;

fn com1_init() linksection(b.init) void {
    cpu.outb(com1 + 0x3, 0x80);
    cpu.outb(com1 + 0x0, 0x0c);
    cpu.outb(com1 + 0x1, 0x00);
    cpu.outb(com1 + 0x3, 0x03);
    cpu.outb(com1 + 0x2, 0xc7);
    cpu.outb(com1 + 0x4, 0x00);
}

fn com1_write(c: u8) void {
    while ((cpu.inb(com1 + 0x5) & 0x20) == 0) {}
    if (c == '\n') {
        cpu.outb(com1, '\r');
    }
    cpu.outb(com1, c);
}

pub fn early_init() linksection(b.init) void {
    com1_init();

    const impl_cpu = &ki.bootstrap_cpu.impl;
    impl_cpu.self_ptr = impl_cpu;
    impl_cpu.percpu_offset = 0;

    const impl_cpu_ptr = @intFromPtr(impl_cpu);
    asm volatile ("wrmsr"
        :
        : [_] "{eax}" (@as(u32, @intCast(impl_cpu_ptr & 0xFFFFFFFF))),
          [_] "{edx}" (@as(u32, @truncate(impl_cpu_ptr >> 32))),
          [_] "{ecx}" (0xC000_0101),
    );

    cpu.detect_cpu_features();

    const f = cpu.cpu_features;

    std.log.info("amd64/cpu: {s}", .{&f.brand_string});
    std.log.info("amd64/cpu: vendor={s} x2apic={} la57={} nx={} pcid={} pge={} smap={} smep={} pdpe1g={} invtsc={} xsave={} fxsave={} tsc-deadline={}", .{
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
}

pub fn late_init() void {}

pub fn devices_init() void {}

pub fn debug_write(c: u8) void {
    com1_write(c);
}

pub fn arm_timer(_: u64) void {}
