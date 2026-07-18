//! Platform interface: each port must implement these functions and variables.
//! To add a new platform, create a new file and implement all required functions.

const config = @import("config");
const r = @import("root");

pub const impl = switch (config.arch) {
    .amd64 => @import("pc/impl.zig"),
    else => @compileError("unsupported architecture"),
};

pub const acpi = @import("acpi/root.zig");

/// Early platform-specific initialization, called before anything else.
pub inline fn early_init() void {
    return impl.early_init();
}

/// Late platform init. Memory allocator is available at this point.
/// SMP bringup must be done after this returns.
pub inline fn late_init() void {
    return impl.late_init();
}

/// Write a single character to the debug console.
pub inline fn debug_write(c: u8) void {
    return impl.debug_write(c);
}

/// Read a single character from the debug console.
pub inline fn debug_read() u8 {
    return impl.debug_read();
}

/// Arm a one-shot timer to fire in `ns` nanoseconds.
pub inline fn arm_timer(ns: u64) void {
    return impl.arm_timer(ns);
}

/// Pretty name for the platform.
pub const name = impl.name;
