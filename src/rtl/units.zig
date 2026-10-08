/// Type-safe measurement units.
const std = @import("std");

pub const Duration = struct {
    /// Value, in nanoseconds.
    value: u64,

    pub fn ns(count: u64) Duration {
        return .{ .value = count };
    }

    pub fn us(count: u64) Duration {
        return .{ .value = std.time.ns_per_us * count };
    }

    pub fn ms(count: u64) Duration {
        return .{ .value = std.time.ns_per_ms * count };
    }

    pub fn seconds(count: u64) Duration {
        return .{ .value = std.time.ns_per_s * count };
    }

    pub fn to_us(duration: Duration) u64 {
        return duration.value / std.time.ns_per_us;
    }

    pub fn to_ms(duration: Duration) u64 {
        return duration.value / std.time.ns_per_ms;
    }

    pub fn to_seconds(duration: Duration) u64 {
        return duration.value / std.time.ns_per_s;
    }
};

pub const Timestamp = struct {
    /// Value, in nanoseconds.
    value: u64,

    pub fn add(now: Timestamp, duration: Duration) Timestamp {
        return .{ .value = now.value + duration.value };
    }

    pub fn to_us(timestamp: Timestamp) u64 {
        return timestamp.value / std.time.ns_per_us;
    }

    pub fn to_ms(timestamp: Timestamp) u64 {
        return timestamp.value / std.time.ns_per_ms;
    }

    pub fn to_seconds(timestamp: Timestamp) u64 {
        return timestamp.value / std.time.ns_per_s;
    }
};
