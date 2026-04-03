pub const private = @import("private.zig");

const b = @import("base");
const std = @import("std");

pub const page_size = 4096;

pub const init = private.init.init;

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

pub fn page_to_pfn(addr: usize) Pfn {
    return @intCast(addr >> 12);
}

pub const p2v = private.impl.phys_to_virt;
pub const v2p = private.impl.virt_to_phys;
