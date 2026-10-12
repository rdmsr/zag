//! Flattened device tree (FDT) parsing.

const std = @import("std");
const assert = std.debug.assert;

const rtl = @import("rtl");

bytes: []const u8,
header: Header,

const fdt_magic = 0xd00dfeed;
const Fdt = @This();

const Header = extern struct {
    magic: u32,
    total_size: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

const TokenId = enum(u32) {
    BeginNode = 1,
    EndNode = 2,
    Property = 3,
    Nop = 4,
    End = 9,
};

pub const Error = error{
    InvalidMagic,
    MalformedHeader,
    InvalidSize,
    InvalidToken,
};

pub const IterError = error{
    InvalidString,
    Truncated,
};

pub const IterMode = enum {
    Nodes,
    Properties,
    Values,
};

pub const EvalError = IterError || error{
    NotANode,
    NotFound,
};

pub const Node = struct {
    name: []const u8,
    offset: usize,

    pub fn iter(
        node: *const Node,
        fdt: *const Fdt,
        comptime mode: IterMode,
    ) IteratorType(mode) {
        return .{
            .core = .{
                .fdt = fdt,
                .offset = node.offset,
            },
        };
    }
};

pub const Property = struct {
    name: []const u8,
    value: []const u8,

    pub fn as_type(self: *const Property, comptime T: type) T {
        return std.mem.readInt(T, self.value[0..@sizeOf(T)], .big);
    }
};

pub const Value = union(enum) {
    Node: Node,
    Property: Property,
};

const IteratorCore = struct {
    fdt: *const Fdt,
    offset: usize,

    fn read_u32_at_offset(self: *IteratorCore) IterError!u32 {
        const value = std.mem.readInt(
            u32,
            self.fdt.bytes[self.offset..][0..4],
            .big,
        );

        if (self.offset + 4 >= self.fdt.bytes.len) {
            return error.Truncated;
        }

        self.offset += @sizeOf(u32);
        return value;
    }

    /// Skip until the offset is at a 4-byte boundary.
    fn align_offset(self: *IteratorCore) void {
        self.offset = (self.offset + 3) & ~@as(usize, 3);
    }
};

fn IterType(comptime mode: IterMode) type {
    return switch (mode) {
        .Nodes => Node,
        .Properties => Property,
        .Values => Value,
    };
}

fn IteratorType(comptime mode: IterMode) type {
    return struct {
        core: IteratorCore,

        const Iterator = @This();

        /// Returns the next token in the node, if any.
        pub fn next(self: *Iterator) IterError!?IterType(mode) {
            var depth: usize = 0;
            var node: ?Node = null;

            while (true) {
                const raw_token_id = try self.core.read_u32_at_offset();

                // Ensure the offset gets advanced.
                const token_id: TokenId = @fromBackingInt(raw_token_id);
                const bytes = self.core.fdt.bytes;

                switch (token_id) {
                    .BeginNode => {
                        const offset = self.core.offset;

                        const null_byte = std.mem.indexOfScalar(
                            u8,
                            bytes[offset..],
                            0,
                        ) orelse return error.InvalidString;

                        const name = bytes[offset .. offset + null_byte];

                        // Skip past the null byte.
                        self.core.offset += null_byte + 1;
                        self.core.align_offset();

                        if (depth == 0) {
                            node = .{
                                .name = name,
                                .offset = self.core.offset,
                            };
                        }
                        depth += 1;
                    },

                    .Property => {
                        const length = try self.core.read_u32_at_offset();
                        const name_off = try self.core.read_u32_at_offset();
                        const off_strings = self.core.fdt.header.off_dt_strings;

                        const name_raw = bytes[off_strings..][name_off..];
                        const name_null = std.mem.indexOfScalar(
                            u8,
                            name_raw,
                            0,
                        ) orelse
                            return error.InvalidString;

                        const name = name_raw[0..name_null];
                        const value = bytes[self.core.offset..][0..length];

                        self.core.offset += length;
                        self.core.align_offset();

                        if (mode != .Nodes) {
                            const prop: Property = .{
                                .name = name,
                                .value = value,
                            };

                            if (mode == .Values) {
                                if (depth == 0) return .{ .Property = prop };
                            } else {
                                if (depth == 0) return prop;
                            }
                        }
                    },

                    .EndNode => {
                        if (depth == 0) return null;

                        depth -= 1;

                        if (mode != .Properties) {
                            if (mode == .Values) {
                                if (depth == 0) return .{ .Node = node.? };
                            } else {
                                if (depth == 0) return node.?;
                            }
                        }
                    },

                    .End => return null,
                    .Nop => continue,
                }
            }
        }
    };
}

pub const ReservedMemoryEntry = struct {
    address: u64,
    size: u64,
};

const ReservedMemoryIterator = struct {
    fdt: *const Fdt,
    offset: usize,

    /// Return the next reserved memory entry in the parsing context, if any.
    pub fn next(self: *ReservedMemoryIterator) IterError!?ReservedMemoryEntry {
        const address = try self.read_u64_at_offset();
        const size = try self.read_u64_at_offset();

        if (address == 0 and size == 0) return null;

        return .{ .address = address, .size = size };
    }

    fn read_u64_at_offset(self: *ReservedMemoryIterator) IterError!u64 {
        const value = std.mem.readInt(
            u64,
            self.fdt.bytes[self.offset..][0..8],
            .big,
        );

        if (self.offset + 8 >= self.fdt.bytes.len) {
            return error.Truncated;
        }

        self.offset += @sizeOf(u64);
        return value;
    }
};

/// Initialize a flattened device tree from a byte slice.
pub fn init(bytes: []const u8) Error!Fdt {
    if (bytes.len < @sizeOf(Header)) {
        return Error.InvalidSize;
    }

    const header = rtl.mem.read_struct(Header, bytes, .big);

    if (header.magic != fdt_magic) {
        return Error.InvalidMagic;
    }

    if (bytes.len != header.total_size) {
        return Error.InvalidSize;
    }

    // Only version 17 is supported.
    if (header.version != 17) {
        return Error.MalformedHeader;
    }

    return .{
        .bytes = bytes,
        .header = header,
    };
}

/// Return the tree's root node
pub fn root(self: *const Fdt) Node {
    // Skip begin_node tag and name.
    const offset = self.header.off_dt_struct + 8;

    return .{
        .name = "\x00",
        .offset = offset,
    };
}

/// Return the index of the boot CPU id.
pub fn boot_cpu_id(self: *const Fdt) u32 {
    return self.header.boot_cpuid_phys;
}

/// Return an iterator over the reserved memory map entries.
pub fn reserved_memory_iter(self: *const Fdt) ReservedMemoryIterator {
    return .{
        .fdt = self,
        .offset = self.header.off_mem_rsvmap,
    };
}

/// Evaluate a device tree path and return the value, if found.
/// Trailing slashes are not handled and will return `NotFound`.
pub fn eval_path(self: *const Fdt, path: []const u8) EvalError!Value {
    var path_iter = std.mem.splitScalar(u8, path, '/');
    var cur_node = self.root();

    // Skip '/'
    _ = path_iter.next();

    while (path_iter.next()) |component| {
        var it = cur_node.iter(self, .Values);
        var found = false;

        inner: while (try it.next()) |val| {
            switch (val) {
                .Property => |prop| {
                    if (std.mem.eql(u8, prop.name, component)) {
                        if (path_iter.peek() != null) {
                            // Path got cut short by a property.
                            return error.NotANode;
                        }

                        return .{ .Property = prop };
                    }
                },
                .Node => |node| {
                    if (std.mem.eql(u8, node.name, component)) {
                        if (path_iter.peek() == null) {
                            // Node path was passed.
                            return .{ .Node = node };
                        }

                        // Go deeper.
                        cur_node = node;
                        found = true;
                        break :inner;
                    }
                },
            }
        }

        if (!found) {
            return error.NotFound;
        }
    }

    unreachable;
}

// /dts-v1/;
// /memreserve/ 0x80000000 0x100000;
// /memreserve/ 0xDEADBEEF 0xC001C0DE;
// / {
//     compatible = "zag";
//     model = "dummy";
//     blabla = <0x69420>;
//     test-empty;
//
//     beatles {
//         names = "john,paul,george,ringo";
//     };
//     empty_node {
//     };
//     nest {
//         grandchild {};
//     };
// };

test "parses the reserved memory" {
    const bytes align(4) = @embedFile("test.dtb").*;
    var fdt = (try Fdt.init(&bytes)).reserved_memory_iter();

    var val = try fdt.next() orelse unreachable;
    try std.testing.expectEqual(0x80000000, val.address);
    try std.testing.expectEqual(0x100000, val.size);

    val = try fdt.next() orelse unreachable;
    try std.testing.expectEqual(0xDEADBEEF, val.address);
    try std.testing.expectEqual(0xC001C0DE, val.size);

    // Ensure there are no more nodes.
    try std.testing.expectEqual(null, try fdt.next());
}

test "parses root node properties" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);
    var it = fdt.root().iter(&fdt, .Properties);

    // Check 'compatible'
    var prop = try it.next() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("compatible", prop.name);
    try std.testing.expectEqualSlices(
        u8,
        "zag\x00",
        prop.value,
    );

    prop = try it.next() orelse
        return error.TestUnexpectedResult;

    // Check 'model'
    try std.testing.expectEqualStrings("model", prop.name);
    try std.testing.expectEqualSlices(
        u8,
        "dummy\x00",
        prop.value,
    );

    prop = try it.next() orelse
        return error.TestUnexpectedResult;

    // Check 'blabla'
    try std.testing.expectEqualStrings("blabla", prop.name);
    try std.testing.expectEqual(
        0x69420,
        prop.as_type(u32),
    );
}

test "parses empty property" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);
    var it = fdt.root().iter(&fdt, .Properties);

    // Skip other properties.
    _ = try it.next();
    _ = try it.next();
    _ = try it.next();

    const prop = try it.next() orelse
        return error.TestUnexpectedResult;

    // Check 'test-empty'
    try std.testing.expectEqualStrings("test-empty", prop.name);
    try std.testing.expectEqualSlices(
        u8,
        &.{},
        prop.value,
    );
}

test "parses child node" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);
    var it = fdt.root().iter(&fdt, .Nodes);

    // Check 'beatles'.
    const node = try it.next() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("beatles", node.name);

    var node_iter = node.iter(&fdt, .Properties);

    // Check the names of the beatles.
    const prop = try node_iter.next() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("names", prop.name);
    try std.testing.expectEqualSlices(
        u8,
        "john,paul,george,ringo\x00",
        prop.value,
    );

    // Ensure the node ends here.
    try std.testing.expectEqual(null, try node_iter.next());
}

test "parses empty node" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);
    var it = fdt.root().iter(&fdt, .Nodes);

    // Skip beatles node.
    _ = try it.next();

    // Check 'empty_node'.
    const node = try it.next() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("empty_node", node.name);

    var node_iter = node.iter(&fdt, .Properties);

    // Ensure it ends immediately.
    try std.testing.expectEqual(null, try node_iter.next());
}

test "parses nested node" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);
    var it = fdt.root().iter(&fdt, .Nodes);

    // Skip beatles node.
    _ = try it.next();

    // Skip empty node.
    _ = try it.next();

    // Check 'nest'.
    const node = try it.next() orelse
        return error.TestUnexpectedResult;

    var node_iter = node.iter(&fdt, .Nodes);

    // Ensure its child is 'grandchild'
    const child_node = try node_iter.next() orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("grandchild", child_node.name);

    // Ensure this has nothing else.
    try std.testing.expectEqual(null, try node_iter.next());

    // Ensure we're at the end of root.
    try std.testing.expectEqual(null, try it.next());
}

test "eval_path root property" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);

    const model_val = try fdt.eval_path("/model");

    switch (model_val) {
        .Property => |prop| {
            try std.testing.expectEqualStrings("dummy\x00", prop.value);
        },

        else => return error.TestUnexpectedResult,
    }
}

test "eval_path NotANode" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);

    try std.testing.expectError(
        EvalError.NotANode,
        fdt.eval_path("/model/something"),
    );
}

test "eval_path nested property" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);

    const names_val = try fdt.eval_path("/beatles/names");

    switch (names_val) {
        .Property => |prop| {
            try std.testing.expectEqualStrings(
                "john,paul,george,ringo\x00",
                prop.value,
            );
        },

        else => return error.TestUnexpectedResult,
    }
}

test "eval_path root node" {
    const bytes align(4) = @embedFile("test.dtb").*;
    const fdt = try Fdt.init(&bytes);

    const node_val = try fdt.eval_path("/nest");

    switch (node_val) {
        .Node => |node| {
            try std.testing.expectEqualStrings("nest", node.name);
        },

        else => return error.TestUnexpectedResult,
    }
}
