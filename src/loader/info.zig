/// Represents the system memory map.
pub const MemMap = struct {
    /// A memory map entry.
    pub const Entry = struct {
        pub const Type = enum {
            Free,
            Reserved,
            LoaderReclaimable,
            LoaderData,
            AcpiNvs,
            AcpiReclaimable,
        };

        type: Type,
        base: usize,
        size: usize,
    };

    entry_count: usize,
    loader_memory_used: usize,
    entries: [128]Entry,
};

pub const Framebuffer = struct {
    address: usize,
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u8,
};

// Kept in sync with the kernel
pub const page_struct_size = 16;

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
