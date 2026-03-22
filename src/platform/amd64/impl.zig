const entry = @import("entry.zig");

pub const first_init = entry.first_init;

pub fn devices_init() void {}

pub fn debug_write(c: u8) void {
    // Write to debugcon
    asm volatile ("outb %[c], %[port]"
        :
        : [c] "{al}" (c),
          [port] "N{dx}" (@as(u16, 0xe9)),
    );
}

pub fn arm_timer(_: u64) void {}
