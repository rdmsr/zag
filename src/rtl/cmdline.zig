//! Command-line arguments parser.
//! This is used to parse the kernel cmdline.
const std = @import("std");

/// Get the string value of `key` in `cmdline`.
pub fn get_string(cmdline: []const u8, key: []const u8) ?[]const u8 {
    var parts = std.mem.splitAny(u8, cmdline, " ");
    while (parts.next()) |part| {
        if (part.len > key.len + 1 and
            std.mem.startsWith(u8, part, key) and
            part[key.len] == '=')
        {
            return part[key.len + 1 ..];
        }
    }
    return null;
}

/// Get the integer value of `key` in `cmdline`.
pub fn get_number(cmdline: []const u8, key: []const u8) ?i64 {
    const str = get_string(cmdline, key);
    if (str) |s| {
        const res = std.fmt.parseInt(i64, s, 10) catch return null;
        return res;
    }
    return null;
}

test "get_string() should return the value of a key" {
    const cmdline = "foo=bar baz=qux";
    const value = get_string(cmdline, "foo");
    try std.testing.expectEqualStrings("bar", value.?);
    try std.testing.expectEqualStrings("qux", get_string(cmdline, "baz").?);
}

test "get_string() should return null if the key is not found" {
    const cmdline = "foo=bar baz=qux";
    try std.testing.expect(get_string(cmdline, "quux") == null);
}

test "malformed key-value pairs should be ignored" {
    const cmdline = "foo=bar baz qux=quux";
    try std.testing.expectEqualStrings("bar", get_string(cmdline, "foo").?);
    try std.testing.expect(get_string(cmdline, "baz") == null);
    try std.testing.expectEqualStrings("quux", get_string(cmdline, "qux").?);
}

test "get_number() should return the integer value of a key" {
    const cmdline = "foo=42 baz=100";
    try std.testing.expectEqual(42, get_number(cmdline, "foo").?);
    try std.testing.expectEqual(100, get_number(cmdline, "baz").?);
}

test "get_number() should return null if the key is not found or value is not an integer" {
    const cmdline = "foo=42 baz=qux";
    try std.testing.expect(get_number(cmdline, "quux") == null);
    try std.testing.expect(get_number(cmdline, "baz") == null);
}
