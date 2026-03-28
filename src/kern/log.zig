const std = @import("std");
const b = @import("base");
const rtl = @import("rtl");
const pl = b.pl;
const ke = b.ke;
const ki = ke.private;

var console_lock = ke.SpinLock.init();
var console_list: rtl.List = .{ .head = .{ .next = &console_list.head, .prev = &console_list.head } };

/// Represents a console device.
/// This is used as an output device.
pub const Console = struct {
    last_seq: u64,
    write: WriteFn,
    link: rtl.List.Entry,
    pub const WriteFn = *const fn (self: *Console, data: []const u8) void;
};

/// Register a console.
pub fn register_console(console: *Console) void {
    const ipl = console_lock.acquire();
    console_list.insert_tail(&console.link);
    console_lock.release(ipl);

    flush();
}

const ConsoleWriter = struct {
    interface: std.Io.Writer,
    console: *Console,

    pub fn init(console: *Console) ConsoleWriter {
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
                .end = 0,
            },
            .console = console,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, _: usize) std.Io.Writer.Error!usize {
        const self: *ConsoleWriter = @fieldParentPtr("interface", w);

        var total_written: usize = 0;
        for (data) |slice| {
            self.console.write(self.console, slice);
            total_written += slice.len;
        }

        return total_written;
    }
};

var ringbuffer = ki.log_ring.RingBuffer(14, 5).init();

fn flush() void {
    var buf: [512]u8 = undefined;

    // Note: we trylock here because if the lock is already held, that means
    // someone else is already flushing the logs.
    if (console_lock.try_acquire()) |ipl| {
        var it = console_list.iterator();

        while (it.next()) : (it.advance()) {
            const console: *Console = @fieldParentPtr("link", it.get());
            var writer = ConsoleWriter.init(console);

            while (true) {
                const info = ringbuffer.read(console.last_seq, &buf) catch break;

                writer.interface.print("[{:>5}.{:06}] ", .{ info.timestamp / std.time.ns_per_s, info.timestamp / std.time.ns_per_us }) catch break;
                console.write(console, buf[0..info.length]);

                console.last_seq = info.sequence + 1;
            }
        }

        console_lock.release(ipl);
    }
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = level;
    _ = scope;

    var discarder: std.Io.Writer.Discarding = .init(&.{});
    discarder.writer.print(fmt ++ "\n", args) catch return;

    var res = ringbuffer.reserve(discarder.fullCount()) catch return;

    res.info.timestamp = ke.timecounter.read_time_nano();
    res.info.length = @truncate(discarder.fullCount());

    res.buf = std.fmt.bufPrint(res.buf, fmt ++ "\n", args) catch return;

    ringbuffer.publish(res);

    flush();
}
