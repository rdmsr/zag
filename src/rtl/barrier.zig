//! Atomic barrier implementations on various architectures.
//! This is needed since Zig removed @fence.

const builtin = @import("builtin");

/// Read Memory Barrier (Load-Load)
/// Ensures all loads before the barrier complete before any loads after it.
pub inline fn rmb() void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            asm volatile ("" ::: .{ .memory = true });
        },
        .aarch64 => {
            asm volatile ("dmb ishld" ::: .{ .memory = true });
        },
        .arm => {
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        .riscv64, .riscv32 => {
            asm volatile ("fence r,r" ::: .{ .memory = true });
        },
        else => @compileError("unsupported architecture"),
    }
}

/// Write Memory Barrier (Store-Store)
/// Ensures all stores before the barrier complete before any stores after it.
pub inline fn wmb() void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            asm volatile ("" ::: .{ .memory = true });
        },
        .aarch64, .arm => {
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        .riscv64, .riscv32 => {
            asm volatile ("fence rw,w" ::: .{ .memory = true });
        },
        else => @compileError("unsupported architecture"),
    }
}

/// Full Memory Barrier (Load/Store - Load/Store)
pub inline fn mb() void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            asm volatile ("mfence" ::: .{ .memory = true });
        },
        .aarch64, .arm => {
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        .riscv64, .riscv32 => {
            asm volatile ("fence rw,rw" ::: .{ .memory = true });
        },
        else => @compileError("unsupported architecture"),
    }
}
