pub const private = @import("private.zig");

const b = @import("base");
const std = @import("std");

pub const page_size = 4096;

pub const init = private.init.init;
pub const vmem = private.vmem;

// 16 TB of maximum physical memory.
// This should be fine on consumer hardware for at least a decade :^)
pub const Pfn = u32;

pub const Page = struct {
    // Fields used when the page is free.
    next_pfn: Pfn,
    batch_next: Pfn,
    batch_count: u8,
};

pub const MapFlags = packed struct {
    read: bool = true,
    write: bool = false,
    user: bool = false,
    execute: bool = false,
    global: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
};

pub const Error = error{OutOfMemory, InvalidAddress, InvalidSize};

pub inline fn page_to_pfn(addr: usize) Pfn {
    return @intCast(addr >> 12);
}

pub inline fn pfn_to_page(pfn: Pfn) usize {
    return @intCast(pfn << 12);
}

pub inline fn struct_page_to_pfn(page: *Page) Pfn {
    return @intCast((@intFromPtr(page) - private.impl.pfndb_base) / @sizeOf(Page));
}

pub inline fn pfn_to_struct_page(pfn: Pfn) *Page {
    return @ptrFromInt(private.impl.pfndb_base + (@as(usize, @intCast(pfn)) * @sizeOf(Page)));
}

pub var pfndb: [*]Page = @ptrFromInt(private.impl.pfndb_base);

pub const p2v = private.impl.phys_to_virt;
pub const v2p = private.impl.virt_to_phys;
