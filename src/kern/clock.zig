const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const ke = r.ke;
const ki = ke.private;

/// Represents a clock source upon which the kernel can rely.
pub const ClockSource = struct {
    /// Callback that reads the current count.
    read_count: *const fn () u64,
    /// Frequency of the timer in Hz.
    frequency: u64,
    /// Name of the timer.
    name: []const u8,
    /// Quality of the timer.
    /// Used to choose between two ClockSources.
    quality: i16,
    /// Mask to apply to the counter value.
    mask: u64,
    /// Binary scaling exponent for fast ns conversion (0 if unused).
    /// See `ticks_to_ns`.
    p: u64,
    /// Scaled nanoseconds-per-tick multiplier for fast ns conversion (0 if unused).
    /// See `ticks_to_ns`.
    n: u64,
};

var best_clock: ?*ClockSource = null;

const State = struct {
    // Counter value at the time the current ClockSource was selected.
    // Used as the baseline for elapsed time calculation.
    initial_count: u64,
    // Accumulated nanosecond offset from previous ClockSources and overflow events.
    // Added to the current counter's contribution in `read_time`.
    offset: u64,
};

// SeqLock-protected time state.
// Avoids a race on `initial_count` and `offset` with `update_overflow`.
var state = rtl.SeqLock(State).init(.{
    .initial_count = 0,
    .offset = 0,
});

// Convert a ClockSource's count to nanoseconds.
// For 64-bit counters (`mask == maxInt(u64)`), uses a fast multiply-shift path
// via precomputed `p` and `n` to avoid 128-bit division at runtime.
// Falls back to a division-based conversion for narrower counters.
fn ticks_to_ns(cs: *ClockSource, count: u64) u64 {
    if (cs.p != 0) {
        const val: u128 = @as(u128, @intCast(count)) * cs.n;
        return @intCast(val >> @intCast(cs.p));
    }

    return (count * std.time.ns_per_s) / cs.frequency;
}

/// Register a clock source.
/// The provided source will be used if it is the highest quality one available.
/// This function cannot be safely called when the hardware timer has been started, as data races on `best_tc` are not avoided.
pub fn register_source(cs: *ClockSource) void {
    // Precompute scaling factors for the fast multiply-shift path.
    // This is meant to avoid 128-bit division and only use multiplication for 64-bit counters.
    if (cs.mask == std.math.maxInt(u64)) {
        cs.p = std.math.log2_int_ceil(u64, cs.frequency);
        cs.n = (@as(u64, std.time.ns_per_s) << @intCast(cs.p)) / cs.frequency;
    } else {
        cs.p = 0;
        cs.n = 0;
    }

    // If the best TimeCounter changed, pass the baton:
    // snapshot the old counter's elapsed time into `offset` and
    // reset `initial_count` to the new counter's current value.
    if (best_clock == null or cs.quality > best_clock.?.quality) {
        const old_best = best_clock;
        best_clock = cs;

        if (old_best) |old| {
            const old_count = old.read_count() & old.mask;
            state.raw.offset = ticks_to_ns(old, old_count);
        }

        state.raw.initial_count = cs.read_count() & cs.mask;
    }
}

/// Return the time elapsed since boot in nanoseconds.
pub fn read_time() r.Nanoseconds {
    const cs = best_clock orelse return 0;

    const s = state.load();
    const curr_count = cs.read_count() & cs.mask;
    const elapsed = (curr_count - s.initial_count) & cs.mask;
    return s.offset + ticks_to_ns(cs, elapsed);
}

/// Return the best clock source.
pub fn best() ?*ClockSource {
    return best_clock;
}

/// Return whether the current best clock is better than `cs`.
pub fn is_better_than(cs: *ClockSource) bool {
    if (best_clock) |b| {
        return b.quality > cs.quality;
    }
    return false;
}

/// Do a busy sleep of `ns` nanoseconds.
pub fn sleep(ns: r.Nanoseconds) void {
    const start = read_time();

    while (true) {
        var cur = read_time();

        if (cur < start) continue;

        if (cur - start >= ns) {
            cur = read_time();

            // Check again as we may have overflowed and read a bogus value.
            // This is kinda hacky but oh well.
            if (cur - start >= ns) {
                break;
            }
        }

        std.atomic.spinLoopHint();
    }
}

/// Called periodically to handle counter overflows.
pub fn update_overflow() void {
    const cs = best_clock orelse return;
    const s = state.load();
    const cur_count = cs.read_count() & cs.mask;

    if (s.initial_count > cur_count) {
        // Counter has wrapped, use wrapping arithmetic to figure out by how much,
        // then fold it into the offset and reset `initial_count`.
        const overflowed_by = (cur_count -% s.initial_count) & cs.mask;
        state.store(.{
            .initial_count = cur_count,
            .offset = s.offset + ticks_to_ns(cs, overflowed_by),
        });
    }
}
