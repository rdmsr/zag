//! Pseudo-random generator used for DST.
//! Adapted from TigerBeetle's PRNG code, itself based on the Zig one.
//! See https://github.com/tigerbeetle/tigerbeetle/blob/main/src/stdx/prng.zig
//! Copyright 2026 TigerBeetle
//! SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");
const math = std.math;
const assert = std.debug.assert;

const Prng = @This();

s: [4]u64,

/// A less than one rational number, used to specify probabilities.
pub const Ratio = struct {
    // Invariant: numerator ≤ denominator.
    numerator: u64,
    // Invariant: denominator ≠ 0.
    denominator: u64,

    pub fn zero() Ratio {
        return .{ .numerator = 0, .denominator = 1 };
    }
};

pub fn from_seed(seed: u64) Prng {
    var s = seed;
    return .{ .s = .{
        split_mix_64(&s),
        split_mix_64(&s),
        split_mix_64(&s),
        split_mix_64(&s),
    } };
}

fn split_mix_64(s: *u64) u64 {
    s.* +%= 0x9e3779b97f4a7c15;

    var z = s.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn next(prng: *Prng) u64 {
    const r = math.rotl(u64, prng.s[0] +% prng.s[3], 23) +% prng.s[0];

    const t = prng.s[1] << 17;

    prng.s[2] ^= prng.s[0];
    prng.s[3] ^= prng.s[1];
    prng.s[1] ^= prng.s[2];
    prng.s[0] ^= prng.s[3];

    prng.s[2] ^= t;

    prng.s[3] = math.rotl(u64, prng.s[3], 45);

    return r;
}

/// Generate an unbiased, uniformly distributed integer r such that 0 ≤ r ≤ max.
pub fn int_inclusive(prng: *Prng, Int: anytype, max: Int) Int {
    comptime assert(@typeInfo(Int).int.signedness == .unsigned);
    if (max == std.math.maxInt(Int)) {
        return prng.int(Int);
    }

    comptime assert(@typeInfo(Int).int.signedness == .unsigned);
    const bits = @typeInfo(Int).int.bits;
    const less_than = max + 1;

    // adapted from:
    //   http://www.pcg-random.org/posts/bounded-rands.html
    //   "Lemire's (with an extra tweak from Zig)"
    var x = prng.int(Int);
    var m = math.mulWide(Int, x, less_than);
    var l: Int = @truncate(m);
    if (l < less_than) {
        var t = -%less_than;

        if (t >= less_than) {
            t -= less_than;
            if (t >= less_than) {
                t %= less_than;
            }
        }
        while (l < t) {
            x = prng.int(Int);
            m = math.mulWide(Int, x, less_than);
            l = @truncate(m);
        }
    }
    return @intCast(m >> bits);
}

/// Generates a uniform, unbiased integer r such that max ≤ r ≤ max.
pub fn range_inclusive(prng: *Prng, Int: type, min: Int, max: Int) Int {
    comptime assert(@typeInfo(Int).int.signedness == .unsigned);
    assert(min <= max);
    return min + prng.int_inclusive(Int, max - min);
}

/// Returns a uniformly distributed integer of type T.
///
/// That is, fills @sizeOf(T) bytes with random bits.
pub fn int(prng: *Prng, Int: type) Int {
    comptime assert(@typeInfo(Int).int.signedness == .unsigned);
    if (Int == u64) return prng.next();
    if (@sizeOf(Int) < @sizeOf(u64)) return @truncate(prng.next());
    var result: std.meta.Int(.unsigned, @sizeOf(Int) * 8) = undefined;
    prng.fill(std.mem.asBytes(&result));
    return @truncate(result);
}

/// Returns true with probability 0.5.
pub fn boolean(prng: *Prng) bool {
    return prng.next() & 1 == 1;
}

/// Returns true with the given rational probability.
pub fn chance(prng: *Prng, probability: Ratio) bool {
    assert(probability.denominator > 0);
    assert(probability.numerator <= probability.denominator);
    return prng.int_inclusive(u64, probability.denominator - 1) <
        probability.numerator;
}
