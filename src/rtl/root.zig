const std = @import("std");

pub const units = @import("units.zig");
pub const List = @import("list.zig").List;
pub const SeqLock = @import("seqlock.zig").SeqLock;
pub const barrier = @import("barrier.zig");
pub const cmdline = @import("cmdline.zig");
pub const pairing_heap = @import("pairing_heap.zig");
pub const PairingHeap = pairing_heap.PairingHeap;
pub const TaggedPtr = @import("tagged_ptr.zig").TaggedPtr;
pub const bst = @import("bst.zig");
pub const BST = bst.BST;
pub const RBTree = @import("rbtree.zig").RBTree;
pub const AVLTree = @import("avl.zig").AVLTree;
pub const BitMap = @import("bitmap.zig").BitMap;
pub const AtomicBitMap = @import("bitmap.zig").AtomicBitMap;
pub const HandoffList = @import("handoff.zig").HandoffList;
pub const LinkerSet = @import("linker_set.zig").LinkerSet;
pub const CachePadded = @import("cache_padded.zig").CachePadded;

pub fn comptime_error(comptime msg: []const u8, args: anytype) void {
    @compileError(std.fmt.comptimePrint(msg, args));
}

/// Asserts that a given type `T` matches the schema declared by `I`.
/// This includes public methods and fields.
pub fn assert_interface(T: type, I: type) void {
    const tinfo = @typeInfo(I);

    const info = tinfo.@"struct";

    inline for (info.field_names, info.field_types) |name, t| {
        if (!@hasField(T, name)) {
            comptime_error(
                "Expected field '{s}' of type '{s}' in type '{s}' required by '{s}'",
                .{
                    name,
                    @typeName(t),
                    @typeName(T),
                    @typeName(I),
                },
            );
        } else {
            if (@FieldType(T, name) != t) {
                comptime_error(
                    "Expected field '{s}' of type '{s}' in type '{s}' required by '{s}', got '{s}'",
                    .{
                        name,
                        @typeName(t),
                        @typeName(T),
                        @typeName(I),
                        @typeName(@FieldType(T, name)),
                    },
                );
            }
        }
    }

    inline for (tinfo.@"struct".decl_names) |decl| {
        const member = @field(I, decl);

        if (@typeInfo(@TypeOf(member)) == .@"fn") {
            if (!@hasDecl(T, decl)) {
                comptime_error(
                    "Expected method '{s}' in type '{s}' required by '{s}'",
                    .{
                        decl,
                        @typeName(T),
                        @typeName(I),
                    },
                );
            }

            const impl_member = @field(T, decl);
            const IfaceFnType = @TypeOf(member);
            const ImplFnType = @TypeOf(impl_member);

            if (IfaceFnType != ImplFnType) {
                const iface_fn = @typeInfo(IfaceFnType).@"fn";
                const impl_fn = @typeInfo(ImplFnType).@"fn";

                if (iface_fn.param_types.len != impl_fn.param_types.len) {
                    comptime_error(
                        "Parameter count mismatch in method '{s}' in type '{s}' required by '{s}'",
                        .{
                            decl,
                            @typeName(T),
                            @typeName(I),
                        },
                    );
                }
                if (iface_fn.return_type != impl_fn.return_type) {
                    comptime_error(
                        "Return type mismatch in method '{s}' in type '{s}' required by '{s}'",
                        .{
                            decl,
                            @typeName(T),
                            @typeName(I),
                        },
                    );
                }

                for (iface_fn.param_types, impl_fn.param_types) |a, b| {
                    if (a != b) {
                        comptime_error(
                            "Parameter type mismatch in method '{s}' in type '{s}' required by '{s}'",
                            .{
                                decl,
                                @typeName(T),
                                @typeName(I),
                            },
                        );
                    }
                }
            }
        } else if (@TypeOf(member) == type) {
            if (!@hasDecl(T, decl)) {
                comptime_error(
                    "Expected type declaration '{s}' in type '{s}' required by '{s}'",
                    .{
                        decl,
                        @typeName(T),
                        @typeName(I),
                    },
                );
            }

            const impl_member = @field(T, decl);
            if (@TypeOf(impl_member) != type) {
                comptime_error(
                    "Declaration '{s}' in type '{s}' is required to be a type by '{s}', but got '{s}'",
                    .{
                        decl,
                        @typeName(T),
                        @typeName(I),
                        @typeName(@TypeOf(impl_member)),
                    },
                );
            }
        } else {
            if (!@hasDecl(T, decl)) {
                comptime_error(
                    "Expected variable declaration '{s}' in type '{s}' required by '{s}'",
                    .{
                        decl,
                        @typeName(T),
                        @typeName(I),
                    },
                );
            }

            const impl_member = @field(T, decl);
            if (@TypeOf(impl_member) != @TypeOf(member)) {
                comptime_error(
                    "Declaration '{s}' in type '{s}' is required to be a variable of type '{s}' by '{s}', but got '{s}'",
                    .{
                        decl,
                        @typeName(T),
                        @typeName(@TypeOf(member)),
                        @typeName(I),
                        @typeName(@TypeOf(impl_member)),
                    },
                );
            }
        }
    }
}

pub fn assert(condition: bool, comptime msg: []const u8, args: anytype) void {
    if (!condition) {
        @branchHint(.unlikely);

        switch (@import("builtin").mode) {
            .fast, .small => unreachable,
            .debug, .safe => {
                std.debug.panicExtra(
                    @returnAddress(),
                    "Assertion failed: " ++ msg,
                    args,
                );
            },
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
