//! MM-level TLB shootdown support

const r = @import("root");
const std = @import("std");

const ke = r.ke;
const mm = r.mm;
const mi = mm.private;
const ps = r.ps;

pub var sync_shootdowns: std.atomic.Value(usize) = .init(0);
pub var async_shootdowns: std.atomic.Value(usize) = .init(0);

fn free_pages(head_pfn: mm.Pfn) void {
    var pfn = head_pfn;

    // Free all the physical pages.
    while (pfn != mm.null_pfn) {
        const page = mm.pfn_to_struct_page(pfn);
        const next = page.free.next_pfn;
        mm.phys.free(mm.pfn_to_page(pfn));
        pfn = next;
    }
}

/// Reclaim the memory associated with a state.
/// This can only be done when all CPUs have flushed their TLB.
fn reclaim_state(state: *ke.ShootdownState) void {
    const space: *mm.Space = @ptrFromInt(state.payload[0]);
    const pfn: u32 = @truncate(state.payload[1]);
    const base = state.base;
    const npages = state.npages;

    // Reclaim the virtual address space.
    const ipl = space.lock.acquire();

    space.arena.free(base, @as(usize, npages) * mm.page_size) catch unreachable;
    space.lock.release(ipl);

    _ = async_shootdowns.fetchAdd(1, .monotonic);

    // Free the physical pages
    free_pages(pfn);

    // Release the slot after all copied state has been consumed.
    state.release();
}

fn worker_thread(_: ?*anyopaque) void {
    while (true) {
        const entry = ke.shootdown.shootdowns.remove();
        const state: *ke.ShootdownState = @fieldParentPtr("link", entry);

        _ = async_shootdowns.fetchAdd(1, .monotonic);
        reclaim_state(state);
    }
}

/// Unmap and flush a virtual range on the given space.
/// Space lock is held on entry and IPL is raised to Dispatch.
pub fn reclaim_range(space: *mm.Space, va: r.VAddr, size: usize) void {
    std.debug.assert(std.mem.isAligned(va, mm.page_size));

    // Unmap the virtual addresses and get the backing physical pages.
    const head_pfn = space.pmap.unmap(va, size) orelse {
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
            @intCast(head_pfn),
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
        free_pages(head_pfn);
        return;
    };
}

pub fn init() void {
    const td = ps.thread.create_kernel(ke.Thread.Priority.default, worker_thread, null) catch unreachable;
    ke.sched.enqueue(&td.kern);
}
