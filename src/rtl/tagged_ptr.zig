/// Struct used to wrap a pointer with a 2-bit tag in the lower bits.
/// This assumes that the pointer is at least 4-byte aligned.
pub fn TaggedPtrType(comptime T: type) type {
    return struct {
        value: usize,

        const Ptr = @This();

        const mask: usize = 0x3;

        pub fn init(ptr_val: *T, tag_val: u2) Ptr {
            return Ptr{
                .value = (@intFromPtr(ptr_val) & ~mask) |
                    (@as(usize, tag_val) & mask),
            };
        }

        /// Return the pointer with the tag bits masked out.
        pub fn ptr(self: *const Ptr) *T {
            return @ptrFromInt(self.value & ~mask);
        }

        /// Set the tag bits to `tag`, while preserving the pointer.
        pub fn set_tag(self: *Ptr, val: u2) void {
            self.value = (self.value & ~mask) | (@as(usize, val) & mask);
        }

        /// Return the tag bits.
        pub fn tag(self: *const Ptr) u2 {
            return @as(u2, @truncate(self.value & mask));
        }

        /// Set the pointer to `ptr`, while preserving the tag bits.
        pub fn set_ptr(self: *Ptr, val: *T) void {
            self.value = (@intFromPtr(val) & ~mask) | (self.value & mask);
        }
    };
}

const std = @import("std");

test TaggedPtrType {
    var x: u32 = 0;
    var tagged = TaggedPtrType(u32).init(&x, 2);

    try std.testing.expectEqual(&x, tagged.ptr());
    try std.testing.expectEqual(2, tagged.tag());

    tagged.set_tag(1);
    try std.testing.expectEqual(1, tagged.tag());

    var y: u32 = 0;
    tagged.set_ptr(&y);
    try std.testing.expectEqual(&y, tagged.ptr());
}
