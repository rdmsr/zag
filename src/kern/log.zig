const std = @import("std");
const b = @import("base");
const pl = b.pl;
const ke = b.ke;

pub var debug_lock = ke.SpinLock.init();

pub fn print(bytes: []const u8) void {
    for (bytes) |c| {
        pl.debug_write(c);
    }
}

const LogWriter = struct {
    interface: std.Io.Writer,

    pub fn init() LogWriter {
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
            print(slice);
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
    _ = scope;

    const ipl = debug_lock.acquire();

    var writer = LogWriter.init();

    writer.interface.print(
        fmt ++ "\r\n",
        args,
    ) catch unreachable;

    debug_lock.release(ipl);
}
