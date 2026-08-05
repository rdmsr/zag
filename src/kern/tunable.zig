//! Tunable kernel parameters.
//! These are variables set in the cmdline at boot and never changed.
const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const pl = r.pl;

const set = rtl.LinkerSet("tunables", *const Entry);

const Entry = struct {
    name: []const u8,
    address: *anyopaque,
    type: union(enum) {
        num: std.builtin.Type.Int,
        bool: void,
    },
};

pub fn Tunable(
    comptime T: type,
    comptime default: T,
    comptime name: []const u8,
) type {
    return struct {
        var storage: T = default;

        const metadata: Entry =
            .{
                .name = name,
                .address = &storage,
                .type = if (T == bool)
                    .bool
                else switch (@typeInfo(T)) {
                    .int => |info| .{ .num = info },
                    else => @compileError("unsupported type"),
                },
            };

        comptime {
            _ = set.insert(&metadata);
        }

        pub fn load() T {
            return storage;
        }
    };
}

fn store_int(comptime T: type, addr: *anyopaque, value: anytype) bool {
    const ptr: *T = @ptrCast(@alignCast(addr));
    ptr.* = std.math.cast(T, value) orelse return false;
    return true;
}

fn apply_num(
    comptime ValueT: type,
    cmdline: []const u8,
    entry: *const Entry,
    info: std.builtin.Type.Int,
) void {
    const value = rtl.cmdline.get_number(ValueT, cmdline, entry.name) catch |e| {
        if (e == error.Format) {
            std.log.warn(
                "Invalid number value for '{s}', falling back.",
                .{entry.name},
            );
        }
        return;
    };

    const sign = @typeInfo(ValueT).int.signedness;

    _ = switch (info.bits) {
        8 => store_int(std.meta.Int(sign, 8), entry.address, value),
        16 => store_int(std.meta.Int(sign, 16), entry.address, value),
        32 => store_int(std.meta.Int(sign, 32), entry.address, value),
        64 => store_int(std.meta.Int(sign, 64), entry.address, value),
        else => unreachable,
    };
}

fn apply_bool(cmdline: []const u8, entry: *const Entry) void {
    const value = rtl.cmdline.get_string(cmdline, entry.name) orelse return;
    const ptr: *bool = @ptrCast(@alignCast(entry.address));

    if (std.mem.eql(u8, value, "true")) {
        ptr.* = true;
    } else if (std.mem.eql(u8, value, "false")) {
        ptr.* = false;
    } else {
        std.log.warn(
            "Invalid cmdline boolean value for tunable '{s}'",
            .{entry.name},
        );
    }
}

pub fn init() void {
    const cmdline = r.boot_info.cmdline orelse return;

    for (set.elems()) |entry| {
        switch (entry.type) {
            .num => |info| switch (info.signedness) {
                .unsigned => apply_num(u64, cmdline, entry, info),
                .signed => apply_num(i64, cmdline, entry, info),
            },
            .bool => apply_bool(cmdline, entry),
        }
    }
}
