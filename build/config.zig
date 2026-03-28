const std = @import("std");
const builtin = @import("builtin");

pub const Config = std.StringHashMap([]const u8);

pub const Bootloader = enum {
    Limine,
};

pub const Platform = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,

    bootloader: ?Bootloader = null,
};

pub fn parseConfig(b: *std.Build) !Config {
    const file = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, ".config", b.allocator, std.Io.Limit.unlimited);

    var lines = std.mem.splitScalar(u8, file, '\n');

    var map = std.StringHashMap([]const u8).init(b.allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) {
            continue;
        }

        var kv = std.mem.splitScalar(u8, trimmed, '=');
        const key = kv.first();
        const value = kv.rest();

        try map.put(key, value);
    }

    return map;
}

pub fn configStep(b: *std.Build) *std.Build.Step {
    return &b.addSystemCommand(&.{ "bash", "build/menuconfig" }).step;
}

fn isInteger(str: []const u8) bool {
    _ = std.fmt.parseInt(i64, str, 10) catch return false;
    return true;
}

pub fn generateConfig(b: *std.Build, config: Config) !*std.Build.Step.WriteFile {
    var out = std.Io.Writer.Allocating.init(b.allocator);

    var it = config.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        if (std.mem.eql(u8, value, "y")) {
            try out.writer.print("pub const {s}: bool = true;\n", .{key});
        } else if (isInteger(value)) {
            try out.writer.print("pub const {s}: i64 = {s};\n", .{ key, value });
        } else {
            try out.writer.print("pub const {s} = \"{s}\";\n", .{ key, value });
        }
    }

    const wf = b.addWriteFiles();

    _ = wf.add("config.gen.zig", out.written());
    _ = wf.addCopyFile(b.path(".config"), ".config");

    return wf;
}

pub fn getPlatform(config: Config) !Platform {
    const keys = .{
        .{ "CONFIG_ARCH_AMD64", Platform{ .arch = .x86_64, .os = .freestanding } },
        .{ "CONFIG_ARCH_AARCH64", Platform{ .arch = .aarch64, .os = .freestanding } },
        .{ "CONFIG_ARCH_RISCV64", Platform{ .arch = .riscv64, .os = .freestanding } },
        .{ "CONFIG_ARCH_UM", Platform{ .arch = builtin.cpu.arch, .os = .linux } },
    };

    var ret = blk: {
        inline for (keys) |entry| {
            if (config.get(entry[0])) |val| {
                if (std.mem.eql(u8, val, "y")) break :blk entry[1];
            }
        }

        return error.NoArchConfigured;
    };

    if (ret.arch == .x86_64 or ret.arch == .aarch64) {
        ret.bootloader = blk: {
            if (config.get("CONFIG_BOOT_LIMINE")) |val| {
                if (std.mem.eql(u8, val, "y")) break :blk .Limine;
            }

            return error.NoBootloaderConfigured;
        };
    }

    return ret;
}
