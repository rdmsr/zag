//! Safe memory reclamation implementation.
//! based on FreeBSD's "Global Unbounded Sequences".

const r = @import("root");
const rtl = @import("rtl");
const std = @import("std");
const config = @import("config");

const ke = r.ke;

const Sequence = u64;

pub const seq_invalid: Sequence = 0;
const seq_init: Sequence = 1;
const seq_incr: Sequence = 1;

/// Represents a domain's clock state,
/// indicating the current sequences.
const Clock = struct {
    /// Minimum observed read sequence
    read_seq: std.atomic.Value(Sequence),
    write_seq: std.atomic.Value(Sequence),
};

/// Represents a single SMR domain.
pub const Domain = struct {
    clock: Clock,
    cpus: [*]Cpu,

    fn cpu(dom: *Domain) *Cpu {
        return &dom.cpus[ke.cpu.current()];
    }

    pub fn init(self: *Domain) void {
        self.clock.read_seq = .init(seq_init);
        self.clock.write_seq = .init(seq_init);

        for (0..ke.ncpus) |i| {
            self.cpus[i].current_seq = .init(seq_invalid);
        }
    }
};

/// Represents per-CPU domain state.
pub const Cpu = struct {
    /// Current observed sequence.
    current_seq: std.atomic.Value(Sequence),
};

/// Scan all CPUs and return the minimum observed value.
/// If `wait` is true, this will spinloop until all CPUs have reached the given goal.
fn scan(dom: *Domain, goal: Sequence, clock: Clock, wait: bool) Sequence {
    rtl.barrier.mb();

    const clk_write = clock.write_seq.raw;
    const clk_read = clock.read_seq.raw;

    // Current minimum value.
    var read_seq = clk_write;

    for (0..ke.ncpus) |i| {
        const cpu = &dom.cpus[i];

        var seq = cpu.current_seq.load(.monotonic);

        while (seq != seq_invalid) {
            if (seq < clk_read) {
                // The sequence for this CPU is somehow lower than the
                // current read sequence. This is caused by the race
                // explained in enter(). Treat the stale reader as if
                // it entered at clk_read instead to prevent it from advancing
                // until the section has expired.
                seq = clk_read;
            }

            if (goal <= seq) {
                // The goal has been reached.
                break;
            }

            if (!wait) break;

            // Wait until the current sequence is changed,
            // this does not guarantee that we've reached the goal yet, but
            // it also lets us detect possible stale values.
            std.atomic.spinLoopHint();
            seq = cpu.current_seq.load(.monotonic);
        }

        if (seq != seq_invalid) {
            // Update the minimum read sequence.
            read_seq = @min(read_seq, seq);
        }
    }

    // The orderings here serve two purposes:
    // 1. All subsequent operations are ordered after the sequence has advanced.
    // 2. Fast-path pollers must see all operations before the updated read_seq.
    // (1) is done by the acquire fence below, and (2) is done by the release
    // success ordering in the CAS. This pairs with the load acquire in poll().
    // It would also be valid to relax the CAS and have a full fence here.
    rtl.barrier.acq();

    // Advance the global read sequence.
    var dom_rd_seq = dom.clock.read_seq.load(.acquire);

    while (read_seq > dom_rd_seq) {
        if (dom.clock.read_seq.cmpxchgWeak(
            dom_rd_seq,
            read_seq,
            .release,
            .acquire,
        )) |seq| {
            dom_rd_seq = seq;
        } else {
            dom_rd_seq = read_seq;
            break;
        }
    }

    return dom_rd_seq;
}

/// Poll to determine whether all CPUs have reached `goal`.
/// If wait is true then this will spinloop until the goal is met.
/// This will advance the domain read sequence if applicable.
pub fn poll(dom: *Domain, goal: Sequence, wait: bool) bool {
    var clk: Clock = undefined;

    // Load read_seq and write_seq in the right order
    // so that we can't observe a read_seq larger than write_seq.
    // This is to ensure the read_seq <= write_seq invariant.
    clk.read_seq.raw = dom.clock.read_seq.load(.acquire);

    if (goal <= clk.read_seq.raw) {
        // Goal reached.
        return true;
    }

    clk.write_seq.raw = dom.clock.write_seq.load(.monotonic);

    const oldest = scan(dom, goal, clk, wait);

    if (goal <= oldest) {
        return true;
    }

    return false;
}

/// Advance the write sequence and return the value for use as a wait goal.
/// It is guaranteed that all previous memory writes made by
/// the calling thread are visible.
pub fn advance(dom: *Domain) Sequence {
    return dom.clock.write_seq.fetchAdd(seq_incr, .release) + seq_incr;
}

/// Enter a read section.
pub fn enter(dom: *Domain) ke.Ipl {
    const ipl = ke.ipl.raise(.Dispatch);
    const cpu = dom.cpu();

    // Store the currently observed write sequence into our CPU state.
    // Subsequent loads must not be re-ordered w.r.t to the store here.
    // On AMD64, we can simply use XADD as this is faster and provides the same guarantees,
    // on other architectures we have to rely on a full (seq_cst) fence.
    // The add operation works because cpu.current_seq is always only 0 (seq_invalid)
    // when we write to it.
    //
    // There can be a large pause between the load from the domain write sequence
    // and the store to the per-cpu state because of e.g an interrupt. This could lead
    // to a state where another CPU advances the global write sequence and current_seq
    // becomes lower than the global write sequence. This is not an issue with the ordering
    // in scan(), which also relies on a full memory barrier, as it is guaranteed that the
    // CPU was treated as inactive and cannot possibly hold a reference to anything the
    // poll declared reclaimable. See scan().
    std.debug.assert(cpu.current_seq.load(.monotonic) == seq_invalid);

    if (config.arch == .amd64) {
        _ = cpu.current_seq.fetchAdd(dom.clock.write_seq.load(.monotonic), .seq_cst);
    } else {
        cpu.current_seq.store(dom.clock.write_seq.load(.monotonic), .monotonic);
        rtl.barrier.mb();
    }

    return ipl;
}

/// Exit a read section.
pub fn exit(dom: *Domain, ipl: ke.Ipl) void {
    const cpu = dom.cpu();

    // Ensure all previous memory ops complete.
    cpu.current_seq.store(seq_invalid, .release);

    ke.ipl.lower(ipl);
}
