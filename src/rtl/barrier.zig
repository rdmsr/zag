//! Atomic barrier implementations on various architectures.
//! This is needed since Zig removed @fence.

const std = @import("std");
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
        .aarch64 => {
            asm volatile ("dmb ishst" ::: .{ .memory = true });
        },
        .arm => {
            asm volatile ("dmb ish" ::: .{ .memory = true });
        },
        .riscv64, .riscv32 => {
            asm volatile ("fence w,w" ::: .{ .memory = true });
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

/// Copy to dest from src with atomic loads.
/// Both addresses need to be aligned.
pub fn atomic_load_memcpy(dest: anytype, src: anytype, comptime ordering: std.builtin.AtomicOrder) void {
    const T = @TypeOf(dest.*);
    const Word = switch (@alignOf(T)) {
        1 => u8,
        2 => u16,
        4 => u32,
        else => u64,
    };

    const word_size = @sizeOf(Word);
    const n = @sizeOf(T);
    comptime std.debug.assert(n % word_size == 0);

    const src_words: [*]const volatile Word = @ptrCast(src);
    const dest_words: [*]Word = @ptrCast(dest);

    var i: usize = 0;
    while (i < n / word_size) : (i += 1) {
        dest_words[i] = @atomicLoad(Word, &src_words[i], ordering);
    }
}

/// Copy to dest from src with atomic stores.
/// Both addresses need to be aligned.
pub fn atomic_store_memcpy(dest: anytype, src: anytype, comptime ordering: std.builtin.AtomicOrder) void {
    const T = @TypeOf(dest.*);
    const Word = switch (@alignOf(T)) {
        1 => u8,
        2 => u16,
        4 => u32,
        else => u64,
    };

    const word_size = @sizeOf(Word);
    const n = @sizeOf(T);
    comptime std.debug.assert(n % word_size == 0);

    const src_words: [*]const volatile Word = @ptrCast(src);
    const dest_words: [*]Word = @ptrCast(dest);

    var i: usize = 0;
    while (i < n / word_size) : (i += 1) {
        @atomicStore(Word, &dest_words[i], src_words[i], ordering);
    }
}
