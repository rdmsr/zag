/// Struct used to wrap a pointer with a 2-bit tag in the lower bits.
/// This assumes that the pointer is at least 4-byte aligned.
pub fn TaggedPtr(comptime T: type) type {
    return struct {
        value: usize,

        const Self = @This();

        const mask: usize = 0x3;

        pub fn init(ptr: *T, tag: u2) Self {
            return Self{ .value = (@intFromPtr(ptr) & ~mask) | (@as(usize, tag) & mask) };
        }

        /// Return the pointer with the tag bits masked out.
        pub fn get_ptr(self: *const Self) *T {
            return @ptrFromInt(self.value & ~mask);
        }

        /// Set the tag bits to `tag`, while preserving the pointer.
        pub fn set_tag(self: *Self, tag: u2) void {
            self.value = (self.value & ~mask) | (@as(usize, tag) & mask);
        }

        /// Return the tag bits.
        pub fn get_tag(self: *const Self) u2 {
            return @as(u2, @truncate(self.value & mask));
        }

        /// Set the pointer to `ptr`, while preserving the tag bits.
        pub fn set_ptr(self: *Self, ptr: *T) void {
            self.value = (@intFromPtr(ptr) & ~mask) | (self.value & mask);
        }
    };
}

const std = @import("std");

test TaggedPtr {
    var x: u32 = 0;
    var tagged = TaggedPtr(u32).init(&x, 2);

    try std.testing.expectEqual(&x, tagged.get_ptr());
    try std.testing.expectEqual(2, tagged.get_tag());

    tagged.set_tag(1);
    try std.testing.expectEqual(1, tagged.get_tag());

    var y: u32 = 0;
    tagged.set_ptr(&y);
    try std.testing.expectEqual(&y, tagged.get_ptr());
}
