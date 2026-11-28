//! riscv64-specific memory management code.
pub const private = @import("private.zig");

const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");

pub const page_size = 4096;

pub const init = private.init.init;
pub const late_init = private.init.late_init;
pub const vmem = private.vmem;
pub const phys = private.phys;
pub const zone = private.zone;
pub const heap = private.heap;
pub const Space = private.Space;
pub const kalloc = private.kalloc;

// 16 TB of maximum physical memory.
// This should be fine on consumer hardware for at least a decade :^)
pub const Pfn = enum(u32) {
    invalid = std.math.maxInt(u32),
    _,

    pub inline fn to_paddr(pfn: Pfn) r.PAddr {
        return pfn.as_usize() << 12;
    }

    pub inline fn from_paddr(addr: r.PAddr) Pfn {
        return @fromBackingInt(@intCast(addr >> 12));
    }

    pub inline fn to_page(pfn: Pfn) *Page {
        return @ptrFromInt(private.impl.pfndb_base +
            (pfn.as_usize() * @sizeOf(Page)));
    }

    pub inline fn from_page(page: *const Page) Pfn {
        const diff: usize = (@intFromPtr(page) - private.impl.pfndb_base) /
            @sizeOf(Page);

        return @fromBackingInt(@intCast(diff));
    }

    pub inline fn as_usize(pfn: Pfn) usize {
        return @as(usize, @backingInt(pfn));
    }
};

pub const PageFree = extern struct {
    link: rtl.List.Entry,
};

pub const Page = extern union {
    free: PageFree,

    pub inline fn to_pfn(page: *const Page) Pfn {
        return Pfn.from_page(page);
    }

    pub inline fn to_paddr(page: *const Page) r.PAddr {
        return page.to_pfn().to_paddr();
    }

    pub inline fn from_paddr(paddr: r.PAddr) *Page {
        return Pfn.from_paddr(paddr).to_page();
    }
};

comptime {
    if (@sizeOf(Page) != r.BootInfo.page_struct_size) {
        @compileError(
            std.fmt.comptimePrint(
                "'Page' size mismatch between loader and kernel: k={} l={}",
                .{ @sizeOf(Page), r.BootInfo.page_struct_size },
            ),
        );
    }
}

pub const MapFlags = bitpack struct {
    read: bool = true,
    write: bool = false,
    user: bool = false,
    execute: bool = false,
    global: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
};

pub const WaitPolicy = enum {
    WaitForMemory,
    DontWaitForMemory,
};

pub const Error = error{ OutOfMemory, InvalidAddress, InvalidSize };

pub var pfndb: [*]Page = @ptrFromInt(private.impl.pfndb_base);

pub const p2v = private.impl.phys_to_virt;
pub const v2p = private.impl.virt_to_phys;
