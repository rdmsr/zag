const std = @import("std");
const builtin = @import("builtin");
const zonfig = @import("zonfig");

pub const Bootloader = enum {
    Limine,
};

pub const Platform = struct {
    arch: std.Target.Cpu.Arch,
    os: std.Target.Os.Tag,
    bootloader: Bootloader = .Limine,
};

const ArchEnum = enum {
    amd64,
    aarch64,
    riscv64,
};

const BootloaderEnum = enum {
    limine,
};

pub const Config = struct {
    arch: ArchEnum,
    bootloader: BootloaderEnum,
};

pub fn parseConfig(b: *std.Build) !Config {
    const gpa = b.allocator;
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var diag: std.zon.parse.Diagnostics = undefined;

    const file = try std.Io.Dir.cwd().readFileAllocOptions(b.graph.io, ".config.zig.zon", b.allocator, std.Io.Limit.unlimited, .@"1", 0);
    return std.zon.parse.fromSlice(
        Config,
        .{
            .gpa = gpa,
            .source = file,
            .arena = arena,
            .diagnostics = &diag,
            .ignore_unknown_fields = true,
        },
    );
}

pub fn getPlatform(config: Config) !Platform {
    var ret = Platform{
        .arch = switch (config.arch) {
            .amd64 => .x86_64,
            .aarch64 => .aarch64,
            .riscv64 => .riscv64,
        },
        .os = .freestanding,
    };

    if (ret.os == .freestanding and (ret.arch == .x86_64 or ret.arch == .aarch64 or ret.arch == .riscv64)) {
        ret.bootloader = switch (config.bootloader) {
            .limine => .Limine,
        };
    }

    return ret;
}
