//! Kernel-side mechanism for asynchronous TLB shootdown and deferred memory reclamation.

const std = @import("std");
const config = @import("config");
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const ki = ke.private;
const mm = r.mm;
const pl = r.pl;

/// Structure representing a single shootdown request.
pub const ShootdownState = struct {
    /// State of the request.
    /// This is used as a counter when the request is outstanding,
    /// otherwise it is set to the `slot_*` values below.
    state: std.atomic.Value(u16),
    link: ?*anyopaque,
    /// Base virtual address of the shootdown.
    base: r.VAddr,
    /// Number of pages to flush.
    npages: u32,
    /// Additional metadata.
    payload: [2]usize,

    pub fn release(self: *ShootdownState) void {
        self.state.store(slot_free, .release);
    }
};

const PerCpu = struct {
    /// States attached to this CPU.
    states: [64]ShootdownState,
    /// States relevant to each CPU.
    /// If CPU0 sent a shootdown to CPU1, then CPU0 will have `valid_states[CPU1]`
    /// pointing to that shootdown, which will sit in `states`.
    valid_states: [config.ncpus]std.atomic.Value(u64),
    /// CPUs that have sent this CPU a shootdown.
    senders: ke.AtomicCpuMask,

    sync_addr: r.VAddr,
    sync_count: usize,
};

const slot_free: u16 = std.math.maxInt(u16);
const slot_reserved: u16 = std.math.maxInt(u16) - 1;
const percpu = ke.CpuLocal(PerCpu, undefined);

pub var shootdowns: rtl.HandoffList = undefined;

fn pcpu_init() linksection(r.init) void {
    const local = percpu.local();

    local.valid_states = @splat(.init(0));
    local.senders = .init(false);
    local.states = @splat(.{
        .base = 0,
        .npages = 0,
        .state = .init(slot_free),
        .payload = undefined,
        .link = undefined,
    });
}

comptime {
    _ = r.percpu_init_set.insert(&pcpu_init);
}

/// Allocate an invalidation state slot on this CPU.
/// O(N) algorithm but N is tiny.
fn allocate_slot(cpu: *PerCpu) ?usize {
    for (0.., &cpu.states) |slot, *state| {
        if (state.state.load(.monotonic) != slot_free) continue;

        if (state.state.cmpxchgStrong(
            slot_free,
            slot_reserved,
            .acquire,
            .monotonic,
        ) == null) {
            return slot;
        }
    }

    return null;
}

fn flush_range(va: r.VAddr, npages: usize) void {
    if (npages > ki.impl.tlb_max_pages) {
        // Just flush the entire thing.
        ki.impl.flush_full_tlb();
        return;
    }

    for (0..npages) |i| {
        ki.impl.flush_tlb(va + i * mm.page_size);
    }
}

/// Synchronous shootdown path.
fn do_synchronous_shootdown(state: ShootdownState) void {
    const cpu = percpu.local();

    cpu.sync_addr = state.base;
    cpu.sync_count = state.npages;

    ke.ipi.broadcast(flush_tlb, null);
}

fn flush_tlb(sender: u32, _: ?*anyopaque) void {
    const cpu = percpu.remote(sender);
    flush_range(cpu.sync_addr, cpu.sync_count);
}

/// Called in a quiescent state to process the pending shootdowns.
/// This must be called at IPL dispatch.
pub fn process_shootdowns() void {
    const cpu = percpu.local();
    const curcpu = ke.cpu.current();

    if (cpu.senders.is_all(false, .monotonic)) {
        // Nothing to do.
        return;
    }

    var iter = cpu.senders.iter(.monotonic);

    // Go through every sender and get their states.
    while (iter.next()) |i| {
        if (i == curcpu) continue;

        cpu.senders.clear(i, .monotonic);

        const sender = percpu.remote(@truncate(i));

        while (true) {
            var states = sender.valid_states[curcpu].swap(0, .acquire);
            if (states == 0) break;

            while (states != 0) {
                // Go through each set bit and invalidate the slot.
                const bit = @ctz(states);
                states &= ~(@as(u64, 1) << @intCast(bit));

                const state = &sender.states[bit];
                flush_range(state.base, state.npages);

                if (state.state.fetchSub(1, .release) == 1) {
                    shootdowns.insert(&state.link);
                }
            }
        }
    }
}

/// Submit a shootdown to occur asynchronously on `target_mask`.
/// Returns an error if a synchronous shootdown was done instead.
pub fn submit(state: ShootdownState, target_mask: ke.CpuMask) !void {
    const ipl = ke.ipl.raise(.Dispatch);
    defer ke.ipl.lower(ipl);

    // Flush on our local TLB.
    flush_range(state.base, state.npages);

    // Get a slot and fill it.
    const curcpu = ke.cpu.current();
    const cpu = percpu.local();
    const slot = allocate_slot(cpu) orelse {
        do_synchronous_shootdown(state);
        return error.NoSlot;
    };

    cpu.states[slot] = state;
    cpu.states[slot].state.store(@truncate(target_mask.count()), .release);

    var iter = target_mask.iter();

    while (iter.next()) |bit| {
        if (bit == curcpu) continue;

        _ = cpu.valid_states[bit].fetchOr(
            @as(u64, 1) << @truncate(slot),
            .release,
        );

        ki.ipl.set_softint_pending(@truncate(bit), .Dispatch);

        // Tell him we have something for him.
        percpu.remote(@truncate(bit)).senders.set(curcpu, .release);
    }
}
