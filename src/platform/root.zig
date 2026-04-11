//! Platform interface: each port must implement these functions and variables.
//! To add a new platform, create a new file and implement all required functions.

const config = @import("config");

pub const impl = if (@hasDecl(config, "CONFIG_ARCH_AMD64"))
    @import("pc/impl.zig")
else if (@hasDecl(config, "CONFIG_ARCH_UM"))
    @import("um/impl.zig")
else
    @compileError("unsupported architecture");

pub const acpi = @import("acpi/root.zig");

/// Early platform-specific initialization, called before anything else.
pub inline fn early_init(boot_info: *BootInfo) void {
    return impl.early_init(boot_info);
}

/// Late platform init. Memory allocator is available at this point.
/// SMP bringup must be done after this returns.
pub inline fn late_init(boot_info: *BootInfo) void {
    return impl.late_init(boot_info);
}

/// Write a single character to the debug console.
pub inline fn debug_write(c: u8) void {
    return impl.debug_write(c);
}

/// Arm a one-shot timer to fire in `ns` nanoseconds.
/// The timer must call `ki_timer_expiry()` when it fires.
pub inline fn arm_timer(ns: u64) void {
    return impl.arm_timer(ns);
}

/// Pretty name for the platform
pub const name = impl.name;

/// A generic struct representing information passed from the bootloader.
pub const BootInfo = struct {
    /// Represents the system memory map.
    pub const MemMap = struct {
        /// A memory map entry.
        pub const Entry = struct {
            pub const Type = enum {
                Free,
                Reserved,
                LoaderReclaimable,
                AcpiNvs,
                AcpiReclaimable,
                Kernel,
            };

            type: Type,
            base: usize,
            size: usize,
        };

        entry_count: usize,
        entries: [256]Entry,
    };

    pub const Framebuffer = struct {
        address: usize,
        width: u32,
        height: u32,
        pitch: u32,
        bpp: u8,
    };

    pub const KernelAddress = struct { physical_base: usize, virtual_base: usize };

    /// RSDP on ACPI machines
    rsdp: ?usize,

    /// Kernel command-line arguments
    cmdline: ?[]const u8,

    /// Memory map
    memory_map: MemMap,

    /// Framebuffer info, if available
    framebuffer: ?Framebuffer,

    /// Kernel address
    kernel_address: KernelAddress,
};
