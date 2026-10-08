const std = @import("std");

pub const Duration = @import("units.zig").Duration;
pub const Timestamp = @import("units.zig").Timestamp;
pub const List = @import("list.zig").List;
pub const SeqLockType = @import("seqlock.zig").SeqLockType;
pub const barrier = @import("barrier.zig");
pub const cmdline = @import("cmdline.zig");
pub const pairing_heap = @import("pairing_heap.zig");
pub const PairingHeapType = pairing_heap.PairingHeapType;
pub const TaggedPtrType = @import("tagged_ptr.zig").TaggedPtrType;
pub const bst = @import("bst.zig");
pub const BstType = bst.BstType;
pub const RbTreeType = @import("rbtree.zig").RbTreeType;
pub const AvlTreeType = @import("avl.zig").AvlTreeType;
pub const BitmapType = @import("bitmap.zig").BitmapType;
pub const AtomicBitmapType = @import("bitmap.zig").AtomicBitmapType;
pub const HandoffList = @import("handoff.zig").HandoffList;
pub const LinkerSetType = @import("linker_set.zig").LinkerSetType;
pub const CachePaddedType = @import("cache_padded.zig").CachePaddedType;

pub fn comptime_error(comptime msg: []const u8, args: anytype) void {
    @compileError(std.fmt.comptimePrint(msg, args));
}

const InterfaceError = enum {
    MissingField,
    FieldType,
    MissingMethod,
    ParameterCount,
    ReturnType,
    ParameterType,
    MissingType,
    TypeDeclaration,
    MissingVariable,
    VariableType,
};

fn interface_error(comptime err: InterfaceError, args: anytype) void {
    const msg = switch (err) {
        .MissingField => "Expected field '{s}' of type '{s}' in type '{s}'" ++
            "required by '{s}'",
        .FieldType => "Expected field '{s}' of type '{s}' in type '{s}'" ++
            "required by '{s}', got '{s}'",
        .MissingMethod => "Expected method '{s}' in type '{s}' " ++
            "required by '{s}'",
        .ParameterCount => "Parameter count mismatch in method '{s}' " ++
            "in type '{s}'" ++ "required by '{s}'",
        .ReturnType => "Return type mismatch in method '{s}' in type '{s}'" ++
            "required by '{s}'",
        .ParameterType => "Parameter type mismatch in method '{s}' in " ++
            "type '{s}' required by '{s}'",
        .MissingType => "Expected type declaration '{s}' in type '{s}'" ++
            "required by '{s}'",
        .TypeDeclaration => "Declaration '{s}' in type '{s}' " ++
            "is required to be a" ++ "type by '{s}', but got '{s}'",
        .MissingVariable => "Expected variable declaration '{s}' " ++
            "in type '{s}'" ++ "required by '{s}'",
        .VariableType => "Declaration '{s}' in type '{s}' is required to be" ++
            "a variable of type '{s}' by '{s}', but got '{s}'",
    };
    comptime_error(msg, args);
}

/// Asserts that a given type `T` matches the schema declared by `I`.
/// This includes public methods and fields.
pub fn assert_interface(T: type, I: type) void {
    const tinfo = @typeInfo(I);

    const info = tinfo.@"struct";

    inline for (info.field_names, info.field_types) |name, t| {
        if (!@hasField(T, name)) {
            interface_error(
                .MissingField,
                .{ name, @typeName(t), @typeName(T), @typeName(I) },
            );
        } else {
            if (@FieldType(T, name) != t) {
                interface_error(
                    .FieldType,
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
                interface_error(
                    .MissingMethod,
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
                    interface_error(
                        .ParameterCount,
                        .{ decl, @typeName(T), @typeName(I) },
                    );
                }
                if (iface_fn.return_type != impl_fn.return_type) {
                    interface_error(
                        .ReturnType,
                        .{ decl, @typeName(T), @typeName(I) },
                    );
                }

                for (iface_fn.param_types, impl_fn.param_types) |a, b| {
                    if (a != b) {
                        interface_error(
                            .ParameterType,
                            .{ decl, @typeName(T), @typeName(I) },
                        );
                    }
                }
            }
        } else if (@TypeOf(member) == type) {
            if (!@hasDecl(T, decl)) {
                interface_error(
                    .MissingType,
                    .{ decl, @typeName(T), @typeName(I) },
                );
            }

            const impl_member = @field(T, decl);
            if (@TypeOf(impl_member) != type) {
                interface_error(
                    .TypeDeclaration,
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
                interface_error(
                    .MissingVariable,
                    .{ decl, @typeName(T), @typeName(I) },
                );
            }

            const impl_member = @field(T, decl);
            if (@TypeOf(impl_member) != @TypeOf(member)) {
                interface_error(
                    .VariableType,
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
