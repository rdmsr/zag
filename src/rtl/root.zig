//! Run-Time Library (RTL) root, implements common algorithms, data structures
//! and helpers for use within the kernel and other related components.
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
pub const mem = @import("mem.zig");

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
    const T_name = @typeName(T);
    const I_name = @typeName(I);

    inline for (info.field_names, info.field_types) |name, t| {
        const t_name = @typeName(t);
        if (!@hasField(T, name)) {
            interface_error(
                .MissingField,
                .{ name, @typeName(t), T_name, I_name },
            );
        } else {
            const FieldType = @FieldType(T, name);

            if (FieldType != t) {
                interface_error(
                    .FieldType,
                    .{ name, t_name, T_name, I_name, @typeName(FieldType) },
                );
            }
        }
    }

    inline for (tinfo.@"struct".decl_names) |decl| {
        const member = @field(I, decl);
        const MemberType = @TypeOf(member);
        const member_type_name = @typeName(MemberType);

        const impl_member = @field(T, decl);
        const ImplType = @TypeOf(impl_member);
        const impl_type_name = @typeName(ImplType);

        if (@typeInfo(@TypeOf(member)) == .@"fn") {
            if (!@hasDecl(T, decl)) {
                interface_error(.MissingMethod, .{ decl, T_name, I_name });
            }

            const IfaceFnType = @TypeOf(member);

            if (IfaceFnType != ImplType) {
                const iface_fn = @typeInfo(IfaceFnType).@"fn";
                const impl_fn = @typeInfo(ImplType).@"fn";

                if (iface_fn.param_types.len != impl_fn.param_types.len) {
                    interface_error(.ParameterCount, .{ decl, T_name, I_name });
                }
                if (iface_fn.return_type != impl_fn.return_type) {
                    interface_error(.ReturnType, .{ decl, T_name, I_name });
                }

                for (iface_fn.param_types, impl_fn.param_types) |a, b| {
                    if (a != b) {
                        interface_error(
                            .ParameterType,
                            .{ decl, T_name, I_name },
                        );
                    }
                }
            }
        } else if (MemberType == type) {
            if (!@hasDecl(T, decl)) {
                interface_error(.MissingType, .{ decl, T_name, I_name });
            }

            if (ImplType != type) {
                interface_error(
                    .TypeDeclaration,
                    .{ decl, T_name, I_name, impl_type_name },
                );
            }
        } else {
            if (!@hasDecl(T, decl)) {
                interface_error(.MissingVariable, .{ decl, T_name, I_name });
            }

            if (ImplType != MemberType) {
                interface_error(
                    .VariableType,
                    .{ decl, T_name, member_type_name, I_name, impl_type_name },
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
