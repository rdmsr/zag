//! Platform-agnostic page map interface.
//!
//! This file defines the `PMap` wrapper and the two built-in mapping sources
//! (`ContiguousSource`, `AllocatingSource`) used to drive `PMap.map_from`.
//!
//! `PMap` itself is a thin wrapper over `mi.impl.PMap`, which is expected to
//! be a `RadixPmap` instantiation (or any type that satisfies the same
//! interface). To add a new platform, provide a concrete `impl.PMap` that
//! exposes:
//!
//!   - `map_from(va: VAddr, size: usize, source: anytype) void`
//!   - `activate() void`
//!
//! Mapping sources are ordinary structs with a single method:
//!
//!   - `next(self: *const Source, va: VAddr) MapItem`
//!
//! `next` is called once per mapping step and returns the physical address,
//! length, and flags for that step. The two sources here cover the common
//! cases (contiguous PA range and on-demand allocation); custom sources can
//! be passed directly to `map_from` for other needs such as file-backed or
//! scatter-gather mappings.
const b = @import("base");
const mm = b.mm;
const mi = mm.private;

/// Describes a contiguous region of physical memory to be mapped at a given virtual address.
pub const MapItem = struct {
    pa: b.PAddr,
    len: usize,
    flags: mm.MapFlags,
};

/// A mapping source that maps a single contiguous virtual-to-physical region.
/// All calls to `next` return the same physical base address and size, so this
/// is intended to be consumed exactly once by `map_from`.
const ContiguousSource = struct {
    flags: mm.MapFlags,
    size: usize,
    base_va: usize,
    base_pa: usize,

    pub fn next(self: *const ContiguousSource, _: b.VAddr) MapItem {
        return .{
            .pa = self.base_pa,
            .len = self.size,
            .flags = self.flags,
        };
    }
};

/// A mapping source that allocates physical pages on demand. Each call to `next`
/// returns a single page, so this is intended to be consumed by `map_from` in a loop until the entire range is mapped.
const AllocatingSource = struct {
    flags: mm.MapFlags,

    pub fn next(self: *const AllocatingSource, _: b.VAddr) MapItem {
        const pa = mi.phys.alloc();
        return .{
            .pa = pa,
            .len = mm.page_size,
            .flags = self.flags,
        };
    }
};

/// Generic wrapper over the platform-specific pmap implementation.
/// Provides some convenient methods for common mapping patterns.
pub const PMap = struct {
    const Self = @This();

    impl: mi.impl.PMap,

    /// Map a virtual address range to physical addresses provided by the source.
    pub fn map_from(self: *Self, va_start: b.VAddr, size: usize, source: anytype) void {
        const Source = @TypeOf(source);

        comptime {
            if (!@hasDecl(Source, "next")) @compileError("source must provide next(self: *Source, va: b.VAddr) MapItem");
        }

        self.impl.map_from(va_start, size, source);
    }

    /// Map a contiguous virtual address range to a contiguous physical address range.
    pub fn map_contiguous_range(self: *Self, va: b.VAddr, pa: b.PAddr, size: usize, flags: mm.MapFlags) void {
        const src = ContiguousSource{
            .flags = flags,
            .size = size,
            .base_va = va,
            .base_pa = pa,
        };

        self.map_from(va, size, src);
    }

    /// Map a virtual address range to physical addresses allocated on demand.
    pub fn map_range_allocating(self: *Self, va: b.VAddr, size: usize, flags: mm.MapFlags) void {
        const src = AllocatingSource{
            .flags = flags,
        };

        self.map_from(va, size, src);
    }

    /// Map a single page. Convenience wrapper around map_contiguous_range.
    pub fn map_page(self: *Self, va: b.VAddr, pa: b.PAddr, flags: mm.MapFlags) void {
        self.map_contiguous_range(va, pa, mm.page_size, flags);
    }

    /// Activate this pagemap.
    pub fn activate(self: *Self) void {
        self.impl.activate();
    }
};
