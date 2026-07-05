const std = @import("std");

/// Used for declaring global objects that get collected by the linker
/// into a `LinkerSet`. This works by declaring each set its own section
/// and abusing linker-generated `__start_<name>` and `__stop_<name>` symbols.
/// Each set stores pointers to objects, so `T` must be a pointer type.
pub fn LinkerSet(name: []const u8, comptime T: type) type {
    if (@typeInfo(T) != .pointer) {
        @compileError("LinkerSet type must be a pointer type");
    }

    return struct {
        const start = @extern(*u8, .{ .name = "__start_set_" ++ name });
        const end = @extern(*u8, .{ .name = "__stop_set_" ++ name });

        const Self = @This();

        pub fn count() usize {
            return (@intFromPtr(end) - @intFromPtr(start)) / @sizeOf(T);
        }

        pub fn elems() []T {
            const n = count();
            const arr: [*]T = @ptrCast(@alignCast(start));

            return arr[0..n];
        }

        pub fn insert(elem: T) type {
            const U = struct {
                var storage: T linksection("set_" ++ name) = elem;

                comptime {
                    _ = &storage;
                }
            };

            return U;
        }
    };
}
