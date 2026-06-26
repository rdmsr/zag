const std = @import("std");

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

/// Asserts that a given type `T` matches the schema declared by `I`.
/// This includes public methods and fields.
pub fn assert_interface(T: type, I: type) void {
    const tinfo = @typeInfo(I);

    inline for (tinfo.@"struct".fields) |f| {
        if (!@hasField(T, f.name)) {
            @compileError(std.fmt.comptimePrint("Expected field '{s}' of type '{s}' in type '{s}' required by '{s}'", .{ f.name, @typeName(f.type), @typeName(T), @typeName(I) }));
        } else {
            if (@FieldType(T, f.name) != f.type) {
                @compileError(std.fmt.comptimePrint("Expected field '{s}' of type '{s}' in type '{s}' required by '{s}', got '{s}'", .{ f.name, @typeName(f.type), @typeName(T), @typeName(I), @typeName(@FieldType(T, f.name)) }));
            }
        }
    }

    inline for (tinfo.@"struct".decls) |decl| {
        const member = @field(I, decl.name);

        if (@typeInfo(@TypeOf(member)) == .@"fn") {
            if (!@hasDecl(T, decl.name)) {
                @compileError(std.fmt.comptimePrint("Expected method '{s}' in type '{s}' required by '{s}'", .{ decl.name, @typeName(T), @typeName(I) }));
            }

            const impl_member = @field(T, decl.name);
            const IfaceFnType = @TypeOf(member);
            const ImplFnType = @TypeOf(impl_member);

            if (IfaceFnType != ImplFnType) {
                const iface_fn = @typeInfo(IfaceFnType).@"fn";
                const impl_fn = @typeInfo(ImplFnType).@"fn";

                if (iface_fn.params.len != impl_fn.params.len) {
                    @compileError(std.fmt.comptimePrint("Parameter count mismatch in method '{s}' in type '{s}' required by '{s}'", .{ decl.name, @typeName(T), @typeName(I) }));
                }
                if (iface_fn.return_type != impl_fn.return_type) {
                    @compileError(std.fmt.comptimePrint("Return type mismatch in method '{s}' in type '{s}' required by '{s}'", .{ decl.name, @typeName(T), @typeName(I) }));
                }

                for (0..iface_fn.params.len) |i| {
                    if (iface_fn.params[i].type != impl_fn.params[i].type) {
                        @compileError(std.fmt.comptimePrint("Parameter type mismatch in method '{s}' in type '{s}' required by '{s}'", .{ decl.name, @typeName(T), @typeName(I) }));
                    }
                }
            }
        } else if (@TypeOf(member) == type) {
            if (!@hasDecl(T, decl.name)) {
                @compileError(std.fmt.comptimePrint("Expected type declaration '{s}' in type '{s}' required by '{s}'", .{ decl.name, @typeName(T), @typeName(I) }));
            }

            const impl_member = @field(T, decl.name);
            if (@TypeOf(impl_member) != type) {
                @compileError(std.fmt.comptimePrint("Declaration '{s}' in type '{s}' is required to be a type by '{s}', but got '{s}'", .{ decl.name, @typeName(T), @typeName(I), @typeName(@TypeOf(impl_member)) }));
            }
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
