//! Kernel logging.

const std = @import("std");
const config = @import("config");
const r = @import("root");

const pl = r.pl;
const ke = r.ke;
const kep = ke.private;
const bv = r.bv;

var out_lock: ke.SpinLock = undefined;

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

    fn drain(
        _: *std.Io.Writer,
        data: []const []const u8,
        _: usize,
    ) std.Io.Writer.Error!usize {
        var total_written: usize = 0;
        for (data) |slice| {
            for (slice) |byte| {
                bv.write_char(byte);
                pl.impl.debug_write(byte);
            }
            total_written += slice.len;
        }

        return total_written;
    }
};

// Messages are on average 2^5 = 32 bytes.
const avg_msg_size_bits = 5;

pub var ringbuffer = kep.log_ring.RingBufferType(
    config.log_buffer_shift,
    avg_msg_size_bits,
).init();

pub var event: ke.Event = undefined;

pub fn init() void {
    out_lock = ke.SpinLock.init("");
    event.init(.Notification);
}

pub fn force_release_lock() void {
    out_lock.release_no_ipl();
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = level;

    const scope_str = if (scope == .default) "" else @tagName(scope) ++ ": ";

    // Calculate the length required.
    const required_len = std.fmt.count(scope_str ++ fmt ++ "\n", args);

    // Reserve space in the ring buffer.
    var res = ringbuffer.reserve(required_len) catch return;

    res.info.timestamp = ke.time.read_time();
    res.info.length = @truncate(required_len);

    // Format the log message into the reserved buffer.
    res.buf = std.fmt.bufPrint(res.buf, scope_str ++ fmt ++ "\n", args) catch
        return;

    ringbuffer.publish(res);

    // Signal whomever is waiting on logs to get published.
    if (@backingInt(ke.ipl.current()) <= @backingInt(ke.Ipl.Dispatch)) {
        event.signal();
    }

    var writer = DebugWriter.init();

    const ipl = out_lock.acquire_at(.High);
    defer out_lock.release(ipl);

    writer.interface.print(
        "[{:>5}.{:06}] ",
        .{
            res.info.timestamp.value / std.time.ns_per_s,
            (res.info.timestamp.value % std.time.ns_per_s) / std.time.ns_per_us,
        },
    ) catch return;
    _ = writer.interface.writeAll(res.buf[0..res.info.length]) catch return;
}
