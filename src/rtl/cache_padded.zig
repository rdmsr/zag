const std = @import("std");

/// Type padded to a cache line.
pub fn CachePadded(comptime T: type) type {
    return struct {
        const cache_line = std.atomic.cache_line;
        const value_size = @sizeOf(T);
        const padded_size = std.mem.alignForward(usize, value_size, cache_line);
        const pad = padded_size - value_size;

        value: T align(cache_line),
        _pad: [pad]u8 = undefined,

        pub fn init(val: T) @This() {
            return .{ .value = val };
        }
    };
}
