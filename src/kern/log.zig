const std = @import("std");
const b = @import("base");
const rtl = @import("rtl");
const pl = b.pl;
const ke = b.ke;
const ki = ke.private;
const config = @import("config");

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
                pl.impl.debug_write(byte);
            }
            total_written += slice.len;
        }

        return total_written;
    }
};

// Messages are on average 2^5 = 32 bytes.
const avg_msg_size_bits = 5;

var ringbuffer = ki.log_ring.RingBuffer(config.CONFIG_LOG_BUFFER_SHIFT, avg_msg_size_bits).init();

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;

    // Calculate the length required.
    const required_len = std.fmt.count(fmt ++ "\n", args);

    // Reserve space in the ring buffer.
    var res = ringbuffer.reserve(required_len) catch return;

    res.info.timestamp = ke.time.read_time_nano();
    res.info.length = @truncate(required_len);

    // Format the log message into the reserved buffer.
    res.buf = std.fmt.bufPrint(res.buf, fmt ++ "\n", args) catch return;

    ringbuffer.publish(res);

    // TODO: for now, we print to the platform's debug output immediately.
    // In the future, we should instead set an event that would get triggered in Ex,
    // which would consume the ringbuffer from multiple consoles in a separate thread.
    var writer = DebugWriter.init();

    writer.interface.print("[{:>5}.{:06}] ", .{ res.info.timestamp / std.time.ns_per_s, res.info.timestamp / std.time.ns_per_us }) catch return;
    _ = writer.interface.writeAll(res.buf[0..res.info.length]) catch return;
}
