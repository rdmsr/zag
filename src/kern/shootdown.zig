//! Kernel-side mechanism for asynchronous TLB shootdown and deferred memory reclamation.

const std = @import("std");
const config = @import("config");
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const ki = ke.private;
const mm = r.mm;

/// Structure representing a single shootdown request.
pub const ShootdownState = struct {
    /// State of the request.
    /// This is used as a counter when the request is outstanding,
    /// otherwise it is set to the `slot_*` values below.
    state: std.atomic.Value(u16),
    link: rtl.List.Entry,
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
};

const slot_free: u16 = std.math.maxInt(u16);
const slot_reserved: u16 = std.math.maxInt(u16) - 1;
const percpu = ke.CpuLocal(PerCpu, undefined);

pub var shootdowns: ke.Queue = undefined;

var sync_counter: std.atomic.Value(usize) = .init(0);
var sync_addr: r.VAddr = 0;
var sync_count: usize = 0;
var shootdown_lock: ke.SpinLock = .init();

fn pcpu_init() linksection(r.init) void {
    const local = percpu.local();

    local.valid_states = @splat(.init(0));
    local.senders = .init(false);
    local.states = @splat(.{ .base = 0, .npages = 0, .state = .init(slot_free), .payload = undefined, .link = undefined });
}

comptime {
    _ = r.percpu_init_set.insert(&pcpu_init);
}

/// Allocate an invalidation state slot on this CPU.
/// O(N) algorithm but N is tiny.
fn allocate_slot(cpu: *PerCpu) ?usize {
    for (0.., &cpu.states) |slot, *state| {
        if (state.state.load(.monotonic) != slot_free) continue;

        if (state.state.cmpxchgStrong(slot_free, slot_reserved, .acquire, .monotonic) == null) {
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
    shootdown_lock.acquire_no_ipl();

    sync_addr = state.base;
    sync_count = state.npages;
    sync_counter.store(ke.ncpus - 1, .release);

    const cur = ke.cpu.current();

    for (0..ke.ncpus) |i| {
        if (i == cur) continue;
        ki.impl.send_tlb_ipi(@truncate(i));
    }

    while (sync_counter.load(.monotonic) != 0) {
        std.atomic.spinLoopHint();
    }

    shootdown_lock.release_no_ipl();
}

/// Called by the TLB interrupt handler.
pub fn ipi_handler() void {
    flush_range(sync_addr, sync_count);
    _ = sync_counter.fetchSub(1, .release);
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
                    shootdowns.insert(&state.link, .Tail);
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

        _ = cpu.valid_states[bit].fetchOr(@as(u64, 1) << @truncate(slot), .release);

        ki.ipl.set_softint_pending(@truncate(bit), .Dispatch);

        // Tell him we have something for him.
        percpu.remote(@truncate(bit)).senders.set(curcpu, .release);
    }
}

pub fn init() void {
    shootdowns.init(ke.ncpus);
}
