const rtl = @import("rtl");
const config = @import("config");
const std = @import("std");

pub const SystemInfo = struct {
    ncpus: usize,
};

pub const BootInfo = @import("info.zig");

const DebugWriter = struct {
    interface: std.Io.Writer,

    pub fn init() DebugWriter {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
                .end = 0,
            },
        };
    }

    fn drain(_: *std.Io.Writer, data: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        var total_written: usize = 0;
        for (data) |slice| {
            for (slice) |byte| {
                arch.debug_write(byte);
            }
            total_written += slice.len;
        }

        return total_written;
    }
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = level;

    const scope_str = if (scope == .default) "" else @tagName(scope) ++ ": ";

    // Calculate the length required.
    var buf: [256]u8 = undefined;

    const written = std.fmt.bufPrint(&buf, scope_str ++ fmt ++ "\n", args) catch return;

    var writer = DebugWriter.init();

    _ = writer.interface.writeAll(written) catch return;
}

pub const std_options = std.Options{
    .logFn = log,
};

comptime {
    _ = @import("limine/impl.zig");
    //_ = &limine;
}

pub const page_size = 0x1000;

pub const ImageLayout = struct {
    physical_base: usize,
    virtual_base: usize,
};

pub const ImplSchema = struct {
    pub fn get_image_layout() ImageLayout {
        return undefined;
    }

    pub fn p2v(pa: usize) usize {
        return pa;
    }
};

pub const arch = switch (config.arch) {
    .amd64 => @import("amd64/impl.zig"),
    else => @compileError("unsupported architecture"),
};

pub const impl = switch (config.bootloader) {
    .limine => @import("limine/impl.zig"),
};

comptime {
    _ = rtl.assert_interface(impl, ImplSchema);
}

pub const main = @import("main.zig").loader_main;

pub const mem = @import("mem.zig");

pub var loader_info: BootInfo = std.mem.zeroes(BootInfo);

fn _panic(
    msg: []const u8,
    _: ?usize,
) noreturn {
    std.log.err("loader panic: {s}", .{msg});

    while (true) {
        asm volatile ("");
    }
}

pub const panic = std.debug.FullPanic(_panic);
