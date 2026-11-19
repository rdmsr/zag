//! Deterministic Simulation Testing (DST) root.
//!
//! ## Intro
//! --------
//! DST is a technique from the database world applied on the kernel to weed out
//! robustness bugs. The basic idea is to shim all the external events into
//! deterministic states which are seeded by a single seed, faults are then
//! injected in a pseudo-random manner and invariants are checked all across
//! the kernel. The kernel must not break an invariant or panic for a given
//! run to succeed. Most of the determinism comes from testing using qemu's
//! icount flag.
//!
//! ## Implementation
//! -----------------
//! This module implements all the common functionality related to DST, and is
//! called by the kernel's entry point when configured for testing.
//! Everything is single-threaded as to avoid complexities on that front,
//! this should be enough as this is meant to test adversarial constraints, not
//! concurrency bugs.
//!
//! For now, this is pretty basic, but I hope this can be extended to simulate
//! e.g failing devices in the future.

const std = @import("std");
const assert = std.debug.assert;

const config = @import("config");

const rtl = @import("rtl");
const Prng = @import("prng.zig");

const Simulation = struct {
    seed: u64,
    prng: Prng,
};

const BuggifyPoint = struct {
    enabled: bool,
    src: std.lang.SourceLocation,
};

var sim: Simulation = undefined;
const buggifies = rtl.LinkerSetType("buggify", *BuggifyPoint);

fn oom() noreturn {
    @panic("OOM");
}

pub const log = std.log.scoped(.dst);

/// Returns true randomly to inject faults.
/// Should be checked alongside error conditions to randomly trigger them.
/// By default, a given point has a 25% x 25% = 6.25% chance of triggering.
pub fn buggify(comptime src: std.lang.SourceLocation) bool {
    if (!config.dst) return false;

    const S = struct {
        var point: BuggifyPoint = .{
            .enabled = false,
            .src = src,
        };
    };

    comptime {
        _ = buggifies.insert(&S.point);
    }

    const enabled = @as(*volatile bool, &S.point.enabled).*;

    // If enabled, return true 25% of the time.
    return enabled and sim.prng.chance(.{ .numerator = 1, .denominator = 4 });
}

/// Get the current DST seed.
pub fn seed() u64 {
    return sim.seed;
}

pub fn init(init_seed: u64) void {
    sim = .{
        .seed = init_seed,
        .prng = .from_seed(init_seed),
    };
}

/// Start sprinkling chaos everywhere.
pub fn enable() void {
    const points = buggifies.elems();

    for (points) |point| {
        // Enable a given point 25% of the time.
        const enabled = sim.prng.chance(.{ .numerator = 1, .denominator = 4 });
        point.*.enabled = enabled;
    }
}
