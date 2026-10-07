//! Wrappers over riscv64 CPU definitions.

pub const name: []const u8 = "riscv64";
pub const BootInfo = struct {};

pub inline fn read_csr(comptime csr: []const u8) u64 {
    return asm volatile ("csrr %[out], " ++ csr
        : [out] "=r" (-> u64),
    );
}

pub inline fn write_csr(comptime csr: []const u8, value: u64) void {
    asm volatile ("csrw " ++ csr ++ ", %[value]"
        :
        : [value] "r" (value),
    );
}

pub inline fn sfence_vma() void {
    asm volatile ("sfence.vma" ::: .{ .memory = true });
}

pub inline fn sfence_vma_page(va: usize) void {
    asm volatile ("sfence.vma %[va], zero"
        :
        : [va] "r" (va),
        : .{ .memory = true });
}
