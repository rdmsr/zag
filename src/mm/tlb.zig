//! MM-level TLB shootdown support

const r = @import("root");
const std = @import("std");
const rtl = @import("rtl");

const ke = r.ke;
const mm = r.mm;
const mi = mm.private;
const ps = r.ps;
const ex = r.ex;

pub var sync_shootdowns: std.atomic.Value(usize) = .init(0);
pub var async_shootdowns: std.atomic.Value(usize) = .init(0);
pub var sent_shootdowns: std.atomic.Value(usize) = .init(0);

var work_item: ex.WorkItem = undefined;

/// Reclaim the memory associated with a state.
/// This can only be done when all CPUs have flushed their TLB.
fn reclaim_state(obj: *anyopaque, _: ?*anyopaque) void {
    const link: *?*anyopaque = @ptrCast(@alignCast(obj));
    const state: *ke.ShootdownState = @fieldParentPtr("link", link);

    const space: *mm.Space = @ptrFromInt(state.payload[0]);
    const pfn_list: mi.PfnList = @bitCast(state.payload[1]);
    const base = state.base;
    const npages = state.npages;

    // Reclaim the virtual address space.
    space.lock.acquire();

    space.arena.free(base, @as(usize, npages) * mm.page_size) catch unreachable;

    space.lock.release();

    // Free the physical pages
    mm.phys.free_batch(mm.pfn_to_struct_page(pfn_list.head), mm.pfn_to_struct_page(pfn_list.tail), npages);

    _ = async_shootdowns.fetchAdd(1, .monotonic);

    // Release the slot after all copied state has been consumed.
    state.release();
}

fn reap_pages(_: ?*anyopaque) void {
    ke.shootdown.shootdowns.process(reclaim_state, null);
}

/// Unmap and flush a virtual range on the given space.
/// Space lock is held on entry and IPL is raised to Dispatch.
pub fn reclaim_range(space: *mm.Space, va: r.VAddr, size: usize) void {
    std.debug.assert(std.mem.isAligned(va, mm.page_size));

    // Unmap the virtual addresses and get the backing physical pages.
    const list = space.pmap.unmap(va, size) orelse {
        // If no physical pages, free the VA directly.
        space.arena.free(va, size) catch unreachable;
        return;
    };

    const state: ke.ShootdownState = .{
        .base = va,
        .npages = @truncate(size / mm.page_size),
        .link = undefined,
        .state = .init(0),
        .payload = .{
            @intFromPtr(space),
            @bitCast(list),
        },
    };

    var mask: ke.CpuMask = .init(false);

    for (0..ke.ncpus) |i| {
        if (i != ke.cpu.current()) {
            mask.set(i);
        }
    }

    ke.shootdown.submit(state, mask) catch {
        _ = sync_shootdowns.fetchAdd(1, .monotonic);
        space.arena.free(va, size) catch unreachable;

        // Free the physical pages
        mm.phys.free_batch(mm.pfn_to_struct_page(list.head), mm.pfn_to_struct_page(list.tail), size / mm.page_size);
        return;
    };
}

fn activation(_: *rtl.HandoffList) void {
    ex.work.enqueue(&work_item);
}

pub fn init() void {
    ke.shootdown.shootdowns.* = .init(activation);
    work_item.init(.High, reap_pages, null);
}
