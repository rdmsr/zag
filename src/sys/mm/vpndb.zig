//! VPNDB implementation.
//!
//! The VPNDB stores metadata information for every page of kernel heap in VPEs.
//! This is used to keep track of heap metadata when a page is not resident and
//! also allows for some optimizations, such as constant-time boundary tag
//! lookup (eventually...).
//!
//! The metadata is allocated lazily when a page is first needed and is stored
//! in a memdesc-esque way, with each VPE containing a tagged pointer.
//!
//! This is akin to the PFNDB, but for virtual pages, hence the name.

const std = @import("std");
const assert = std.debug.assert;

const rtl = @import("rtl");

const r = @import("root");
const mm = r.mm;
const mmp = mm.private;
const ke = r.ke;

const base = mmp.impl.vpndb_base;
const heap_base = mmp.impl.kernel_heap_base;
const vpndb: [*]Vpe = @ptrFromInt(base);
const TaggedPointer = rtl.TaggedPtrType(anyopaque);

pub const Tag = enum(u2) {
    /// This page is unused.
    Free,

    /// This page is used as a slab.
    Slab,
};

pub const Vpe = struct {
    desc: TaggedPointer,

    pub fn set(self: *Vpe, tag: Tag, value: *anyopaque) void {
        self.desc = TaggedPointer.init(value, @backingInt(tag));
    }

    pub fn get(self: *Vpe) struct { Tag, *anyopaque } {
        return .{
            @fromBackingInt(self.desc.tag()),
            self.desc.ptr(),
        };
    }
};

/// Virtual page number.
pub const Vpn = enum(u32) {
    _,

    pub fn from_vaddr(addr: r.VAddr) Vpn {
        return @fromBackingInt(@intCast((addr - heap_base) >> 12));
    }

    pub fn to_vaddr(vpn: Vpn) r.VAddr {
        return (@as(usize, @backingInt(vpn)) << 12) + heap_base;
    }

    pub fn to_vpe(vpn: Vpn) *Vpe {
        return &vpndb[vpn.value()];
    }

    pub fn value(vpn: Vpn) u32 {
        return @backingInt(vpn);
    }
};

/// Create VPEs for the provided range.
/// Space lock is held.
pub fn create_vpes(
    start: r.VAddr,
    npages: usize,
    policy: mm.WaitPolicy,
) mm.Error!void {
    assert(mmp.kernel_space.lock.is_locked());

    const start_index = Vpn.from_vaddr(start).value();

    for (0..npages) |i| {
        const entry = &vpndb[start_index + i];
        const page = std.mem.alignBackward(
            usize,
            @intFromPtr(entry),
            mm.page_size,
        );

        // Do a dummy read to fault the page in if it doesn't exist.
        _ = ke.try_read(u8, @ptrFromInt(page)) catch {
            // Page doesn't exist, allocate it and map it.
            var pa: usize = undefined;

            if (policy == .WaitForMemory) {
                // XXX: better to try allocating first and then drop the lock
                // and wait if that fails.
                mmp.kernel_space.lock.release();
                pa = mm.phys.alloc();
                mmp.kernel_space.lock.acquire();
            } else {
                pa = mm.phys.alloc_opts(.{ .policy = policy }) orelse {
                    return error.OutOfMemory;
                };
            }

            const pte = try mmp.pmap.wire_pte(&mmp.kernel_space, page, policy);

            if (!pte.is_present()) {
                pte.* = mmp.impl.make_leaf_pte(
                    pa,
                    .{ .read = true, .write = true },
                    0,
                );
            } else {
                // Someone else beat us to it.
            }
        };
    }
}
