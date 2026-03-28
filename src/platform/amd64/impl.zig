const b = @import("base");
const ki = b.ke.private;

pub const name = "amd64";

pub fn early_init() void {
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
}

pub fn late_init() void {}

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
