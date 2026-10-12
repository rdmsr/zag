const rtl = @import("rtl");
const r = @import("root");
const rv64 = r.arch;
const ke = r.ke;
const std = @import("std");
extern fn riscv_trap() callconv(.c) void;

// for QEMU virt. for real HW this needs to be parsed from the DTB.
const timebase_hz = 10_000_000;
var time_counter: ke.TimeCounter = .{
    .read_count = read_time,
    .frequency = timebase_hz,
    .name = "riscv time",
    .quality = 100,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

fn read_time() u64 {
    return rv64.read_csr("time");
}

pub const name: []const u8 = "QEMU virt";

pub fn early_init() void {
    rv64.write_csr("stvec", @intFromPtr(&riscv_trap));
}

pub fn late_init() void {
    ke.time.register_source(&time_counter);
    asm volatile ("csrs sie, %[mask]"
        :
        : [mask] "r" (@as(usize, 32)),
        : .{ .memory = true });
}

fn set_timer(deadline: u64) void {
    asm volatile ("ecall"
        :
        : [deadline] "{a0}" (deadline),
          [function] "{a6}" (@as(usize, 0)),
          [extension] "{a7}" (@as(usize, 0x54494d45)),
        : .{ .memory = true });
}

pub fn debug_write(c: u8) void {
    // SBI legacy console putchar.
    asm volatile ("ecall"
        :
        : [char] "{a0}" (@as(usize, c)),
          [extension] "{a7}" (@as(usize, 1)),
        : .{ .memory = true });
}

pub fn debug_read() u8 {
    while (true) {
        const c = asm volatile ("ecall"
            : [char] "={a0}" (-> usize),
            : [extension] "{a7}" (@as(usize, 2)),
            : .{ .memory = true });
        if (c != std.math.maxInt(usize)) return @truncate(c);
    }
}

pub fn send_ipi(_: u32) void {}
pub fn arm_timer(ns: rtl.Duration) void {
    const ticks = @max(1, @as(
        u64,
        @intCast((@as(u128, ns.value) * timebase_hz) / std.time.ns_per_s),
    ));
    set_timer(read_time() +% ticks);
}
