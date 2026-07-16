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

pub fn Tunable(comptime T: type, comptime default: T, comptime name: []const u8) type {
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

pub fn init(boot_info: *r.BootInfo) void {
    const cmdline = boot_info.cmdline orelse return;

    const elems = set.elems();

    for (elems) |entry| {
        switch (entry.type) {
            .num => |info| {
                const a = entry.address;

                switch (info.signedness) {
                    .unsigned => {
                        const value = rtl.cmdline.get_number(u64, cmdline, entry.name) catch |e| {
                            if (e == error.Format) {
                                std.log.warn("Invalid number value for '{s}', falling back.", .{entry.name});
                            }
                            continue;
                        };

                        switch (info.bits) {
                            8 => (@as(*u8, @ptrCast(@alignCast(a)))).* = std.math.cast(u8, value) orelse continue,
                            16 => (@as(*u16, @ptrCast(@alignCast(a)))).* = std.math.cast(u16, value) orelse continue,
                            32 => (@as(*u32, @ptrCast(@alignCast(a)))).* = std.math.cast(u32, value) orelse continue,
                            64 => (@as(*u64, @ptrCast(@alignCast(a)))).* = value,
                            else => unreachable,
                        }
                    },

                    .signed => {
                        const value = rtl.cmdline.get_number(i64, cmdline, entry.name) catch |e| {
                            if (e == error.Format) {
                                std.log.warn("Invalid number value for '{s}', falling back.", .{entry.name});
                            }

                            continue;
                        };

                        switch (info.bits) {
                            8 => (@as(*i8, @ptrCast(@alignCast(a)))).* = std.math.cast(i8, value) orelse continue,
                            16 => (@as(*i16, @ptrCast(@alignCast(a)))).* = std.math.cast(i16, value) orelse continue,
                            32 => (@as(*i32, @ptrCast(@alignCast(a)))).* = std.math.cast(i32, value) orelse continue,
                            64 => (@as(*i64, @ptrCast(@alignCast(a)))).* = value,
                            else => unreachable,
                        }
                    },
                }
            },

            .bool => {
                const value = rtl.cmdline.get_string(cmdline, entry.name) orelse continue;
                const ptr: *bool = @ptrCast(@alignCast(entry.address));

                if (std.mem.eql(u8, value, "true")) {
                    ptr.* = true;
                } else if (std.mem.eql(u8, value, "false")) {
                    ptr.* = false;
                } else {
                    std.log.warn("Invalid cmdline boolean value for tunable '{s}'", .{entry.name});
                }
            },
        }
    }
}
