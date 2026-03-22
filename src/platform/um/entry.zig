const b = @import("base");

pub const std_options = b.std_options;

const std = @import("std");
const ke = b.ke;
const pl = b.pl;

const default_mem_size = b.gib(1);

fn parse_mem_size(str: []const u8) !usize {
    if (str.len == 0) return default_mem_size;

    const last = str[str.len - 1];

    const mul: usize = switch (std.ascii.toLower(last)) {
        'k' => b.kib(1),
        'm' => b.mib(1),
        'g' => b.gib(1),
        else => 1,
    };

    const digits = if (mul == 1) str else str[0 .. str.len - 1];
    const size = try std.fmt.parseInt(usize, digits, 10);
    return size * mul;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const exe = args.next().?;

    var mem_size: usize = default_mem_size;
    var cmdline: ?[]const u8 = null;
    var ncpus: usize = 1;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mem-size")) {
            const val = args.next() orelse fatal("--mem-size requires a value", .{});
            mem_size = parse_mem_size(val) catch fatal("invalid mem-size", .{});
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cmdline")) {
            cmdline = args.next() orelse fatal("--cmdline requires a value", .{});
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            const val = args.next() orelse fatal("--threads requires a value", .{});
            ncpus = std.fmt.parseInt(usize, val, 10) catch fatal("invalid thread count", .{});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &.{});
            var w = &stderr.interface;

            try w.print(
                \\Usage: {s} [options]
                \\  -m, --mem-size SIZE    Set the memory size
                \\  -c, --cmdline STR      Set the kernel cmdline
                \\  -t, --threads COUNT    Set the number of threads
                \\
            , .{exe});
            std.process.exit(0);
        } else {
            fatal("unknown argument: {s}", .{arg});
        }
    }

    pl.impl.global_state.params =
        .{ .ncpus = ncpus, .cmdline = cmdline, .mem_size = mem_size };

    pl.impl.global_state.boot_info.kernel_address.physical_base = 0;
    pl.impl.global_state.boot_info.kernel_address.virtual_base = 0;

    pl.impl.global_state.boot_info.rsdp = 0;
    pl.impl.global_state.boot_info.cmdline = cmdline;

    ke.ncpus = ncpus;

    ke.private.init(&pl.impl.global_state.boot_info);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
