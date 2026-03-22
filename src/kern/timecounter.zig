const std = @import("std");
const rtl = @import("rtl");
const b = @import("base");
const ke = b.ke;
const ki = ke.private;

/// TimeCounter structure.
/// Represents a time-keeping source upon which the kernel can rely.
pub const TimeCounter = struct {
    /// Callback that reads the current count.
    read_count: *const fn () u64,
    /// Frequency of the timer in Hz.
    frequency: u64,
    /// Name of the timer.
    name: []const u8,
    /// Quality of the timer.
    /// Used to choose between two TimeCounters.
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

var best_tc: ?*TimeCounter = null;

const TimeState = struct {
    // Counter value at the time the current TimeCounter was selected.
    // Used as the baseline for elapsed time calculation.
    initial_count: u64,
    // Accumulated nanosecond offset from previous TimeCounters and overflow events.
    // Added to the current counter's contribution in `read_time_nano`.
    offset: u64,
};

// SeqLock-protected time state.
// Avoids a race on `initial_count` and `offset` with `update_overflow`.
var state = rtl.SeqLock(TimeState).init(.{
    .initial_count = 0,
    .offset = 0,
});

// Convert a TimeCounter's count to nanoseconds.
// For 64-bit counters (`mask == maxInt(u64)`), uses a fast multiply-shift path
// via precomputed `p` and `n` to avoid 128-bit division at runtime.
// Falls back to a division-based conversion for narrower counters.
fn ticks_to_ns(tc: *TimeCounter, count: u64) u64 {
    if (tc.p != 0) {
        const val: u128 = @as(u128, @intCast(count)) * tc.n;
        return @intCast(val >> @intCast(tc.p));
    }

    return (count * std.time.ns_per_s) / tc.frequency;
}

/// Register a time-keeping source.
/// The TimeCounter will be used if it is the highest quality one available.
/// This function cannot be safely called when the hardware timer has been started, as data races on `best_tc` are not avoided.
pub fn register(tc: *TimeCounter) void {
    // Precompute scaling factors for the fast multiply-shift path.
    // This is meant to avoid 128-bit division and only use multiplication for 64-bit counters.
    if (tc.mask == std.math.maxInt(u64)) {
        tc.p = std.math.log2_int_ceil(u64, tc.frequency);
        tc.n = (@as(u64, std.time.ns_per_s) << @intCast(tc.p)) / tc.frequency;
    } else {
        tc.p = 0;
        tc.n = 0;
    }

    // If the best TimeCounter changed, pass the baton:
    // snapshot the old counter's elapsed time into `offset` and
    // reset `initial_count` to the new counter's current value.
    if (best_tc == null or tc.quality > best_tc.?.quality) {
        const old_best = best_tc;
        best_tc = tc;

        if (old_best) |old| {
            const old_count = old.read_count() & old.mask;
            state.raw.offset = ticks_to_ns(old, old_count);
        }

        state.raw.initial_count = tc.read_count() & tc.mask;
    }
}

/// Return the time elapsed since boot in nanoseconds.
pub fn read_time_nano() b.Nanoseconds {
    const tc = best_tc orelse return 0;

    const s = state.load();
    const curr_count = tc.read_count() & tc.mask;
    const elapsed = (curr_count - s.initial_count) & tc.mask;
    return s.offset + ticks_to_ns(tc, elapsed);
}

/// Return the best TimeCounter.
pub fn best() ?*TimeCounter {
    return best_tc;
}

/// Do a busy sleep of `ns` nanoseconds using TimeCounter.
pub fn sleep(ns: b.Nanoseconds) void {
    const start = read_time_nano();

    while (true) {
        var cur = read_time_nano();

        if (cur < start) continue;

        if (cur - start >= ns) {
            cur = read_time_nano();

            // Check again as we may have overflowed and read a bogus value..
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
    const tc = best_tc orelse return;
    const s = state.load();
    const cur_count = tc.read_count() & tc.mask;

    if (s.initial_count > cur_count) {
        // Counter has wrapped, use wrapping arithmetic to figure out by how much,
        // then fold it into the offset and reset `initial_count`.
        const overflowed_by = (cur_count -% s.initial_count) & tc.mask;
        state.store(.{
            .initial_count = cur_count,
            .offset = s.offset + ticks_to_ns(tc, overflowed_by),
        });
    }
}
