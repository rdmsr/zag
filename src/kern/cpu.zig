const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const config = @import("config");
const ke = r.ke;
const ki = r.ke.private;

extern var __init_array_percpu_start: u8;
extern var __init_array_percpu_end: u8;

const id = CpuLocal(u32, 0);

/// Initialize a CPU. Must be called on all CPUs.
pub fn init_cpu(cpu_id: u32) void {
    const start = @intFromPtr(&__init_array_percpu_start);
    const end = @intFromPtr(&__init_array_percpu_end);
    const count = (end - start) / @sizeOf(*const fn () void);
    const funcs: [*]const *const fn () callconv(.c) void = @ptrFromInt(start);

    id.local().* = cpu_id;

    for (0..count) |i| {
        funcs[i]();
    }
}

pub fn current() u32 {
    return id.local().*;
}

comptime {
    if (!@hasDecl(ki.impl, "percpu_ptr")) @compileError("impl must provide percpu_ptr()");
    if (!@hasDecl(ki.impl, "percpu_ptr_other")) @compileError("impl must provide percpu_ptr_other()");
}

/// Wraps around CPU-local data.
pub fn CpuLocal(comptime T: type, comptime init: T) type {
    return struct {
        var storage: T linksection(".data.percpu") = init;

        /// Return a pointer to local CPU data.
        pub fn local() @TypeOf(ki.impl.percpu_ptr(&storage)) {
            return ki.impl.percpu_ptr(&storage);
        }

        /// Return a pointer to remote CPU data.
        pub fn remote(cpu: u32) *T {
            return ki.impl.percpu_ptr_other(&storage, cpu);
        }
    };
}

/// Wraps around CPU-local data with a designated symbol name.
pub fn ExportedCpuLocal(comptime T: type, comptime init: T, comptime name: []const u8) type {
    const S = struct {
        var storage: T linksection(".data.percpu") = init;

        pub fn local() @TypeOf(ki.impl.percpu_ptr(&storage)) {
            return ki.impl.percpu_ptr(&storage);
        }
        pub fn remote(cpu: u32) *T {
            return ki.impl.percpu_ptr_other(&storage, cpu);
        }
    };
    @export(&S.storage, .{ .name = name, .linkage = .strong });
    return S;
}

/// Bitmask of CPUs.
pub const CpuMask = struct {
    const bits_per_word = @bitSizeOf(usize);
    const num_words = (config.CONFIG_NCPUS + bits_per_word - 1) / bits_per_word;

    bits: [num_words]usize,

    /// Return an empty `CpuMask`.
    pub fn empty() CpuMask {
        return CpuMask{ .bits = [_]usize{0} ** num_words };
    }

    /// Set the bit corresponding to `cpu_id`.
    pub fn set(self: *CpuMask, cpu_id: usize) void {
        const word_index = cpu_id / bits_per_word;
        const bit_index = cpu_id % bits_per_word;
        self.bits[word_index] |= (@as(usize, 1) << @intCast(bit_index));
    }

    /// Clear the bit corresponding to `cpu_id`.
    pub fn clear(self: *CpuMask, cpu_id: usize) void {
        const word_index = cpu_id / bits_per_word;
        const bit_index = cpu_id % bits_per_word;
        self.bits[word_index] &= ~(@as(usize, 1) << @intCast(bit_index));
    }

    /// Check whether the bit corresponding to `cpu_id` is set.
    pub fn is_set(self: *const CpuMask, cpu_id: usize) bool {
        const word_index = cpu_id / bits_per_word;
        const bit_index = cpu_id % bits_per_word;
        return (self.bits[word_index] & (@as(usize, 1) << @intCast(bit_index))) != 0;
    }

    pub fn is_full(self: *const CpuMask) bool {
        for (self.bits) |word| {
            if (word != std.math.maxInt(usize)) return false;
        }
        return true;
    }
};
