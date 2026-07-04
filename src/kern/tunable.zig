//! Tunable kernel parameters.
//! These are variables set in the cmdline at boot and never changed.
const std = @import("std");
const rtl = @import("rtl");
const r = @import("root");
const pl = r.pl;

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

        const metadata: Entry linksection(".data.tunable") =
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

        pub fn load() T {
            _ = metadata;
            return storage;
        }
    };
}

extern var __tunables_start: u8;
extern var __tunables_end: u8;

pub fn init(boot_info: *pl.BootInfo) void {
    const cmdline = boot_info.cmdline orelse return;

    const start = @intFromPtr(&__tunables_start);
    const end = @intFromPtr(&__tunables_end);
    const count = (end - start) / @sizeOf(Entry);
    const entries: [*]Entry = @ptrFromInt(start);

    for (0..count) |i| {
        switch (entries[i].type) {
            .num => |info| {
                const a = entries[i].address;

                switch (info.signedness) {
                    .unsigned => {
                        const value = rtl.cmdline.get_number(u64, cmdline, entries[i].name) orelse {
                            std.log.warn("Invalid number value for '{s}', falling back.", .{entries[i].name});
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
                        const value = rtl.cmdline.get_number(i64, cmdline, entries[i].name) orelse {
                            std.log.warn("Invalid number value for '{s}', falling back.", .{entries[i].name});
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
                const value = rtl.cmdline.get_string(cmdline, entries[i].name) orelse continue;
                const ptr: *bool = @ptrCast(@alignCast(entries[i].address));

                if (std.mem.eql(u8, value, "true")) {
                    ptr.* = true;
                } else if (std.mem.eql(u8, value, "false")) {
                    ptr.* = false;
                } else {
                    std.log.warn("Invalid cmdline boolean value for tunable '{s}'", .{entries[i].name});
                }
            },
        }
    }
}
