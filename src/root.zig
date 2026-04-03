const std = @import("std");
pub const ke = @import("kern/root.zig");
pub const ex = @import("ex/root.zig");
pub const pl = @import("platform/root.zig");
pub const rtl = @import("rtl");
pub const ksyms = @import("ksyms");
pub const arch = @import("arch");
pub const mm = @import("mm/root.zig");

pub const init = ".text.init";
pub const percpu_init = ".percpu_init_array";
pub const percpu = ".data.percpu";

pub const VAddr = usize;
pub const PAddr = usize;

pub const Nanoseconds = u64;

pub var kernel_heap_base: usize = 0;
pub var kernel_pfndb_base: usize = 0;

/// Return N kibibytes in bytes.
pub fn kib(comptime N: u32) usize {
    return N * 1024;
}

/// Return N mebibytes in bytes.
pub fn mib(comptime N: u32) usize {
    return kib(N) * 1024;
}

/// Return N gibibytes in bytes.
pub fn gib(comptime N: u32) usize {
    return mib(N) * 1024;
}

/// Return N tibibytes in bytes.
pub fn tib(comptime N: u32) usize {
    return gib(N) * 1024;
}

pub const std_options = std.Options{
    .logFn = ke.log.log,
};

pub const panic = std.debug.FullPanic(ke.panic);
