//! Logging (for now) consoles.
const std = @import("std");
const r = @import("root");
const rtl = @import("rtl");
const ke = r.ke;
const ps = r.ps;
const ex = r.ex;

pub const Console = struct {
    link: rtl.List.Entry,
    write: *const fn (ctx: ?*anyopaque, slice: []const u8) void,
    ctx: ?*anyopaque,
};

const ConWriter = struct {
    interface: std.Io.Writer,
    console: *Console,

    pub fn init(console: *Console) ConWriter {
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
        const self: *ConWriter = @fieldParentPtr("interface", w);
        var total_written: usize = 0;
        for (data) |slice| {
            self.console.write(self.console.ctx, slice);
            total_written += slice.len;
        }

        return total_written;
    }
};

var console_list: rtl.List = undefined;
var console_lock: ke.Mutex = .init();
var last_seq: usize = 0;

fn write_on(buf: []u8, rec: anytype, console: *Console) void {
    var writer = ConWriter.init(console);
    writer.interface.writeAll(buf[0..rec.length]) catch unreachable;
}

fn drain_from_on(seq: usize, console: *Console) usize {
    var cur_seq: usize = seq;
    var buf: [1024]u8 = undefined;
    while (true) {
        const rec = ke.log.ringbuffer.read(cur_seq, &buf) catch break;

        write_on(&buf, rec, console);

        cur_seq += 1;
    }

    return cur_seq;
}

fn drain_from_all(seq: usize) usize {
    var cur_seq: usize = seq;
    var buf: [1024]u8 = undefined;
    while (true) {
        const rec = ke.log.ringbuffer.read(cur_seq, &buf) catch break;

        console_lock.acquire();

        var it = console_list.iterator();

        while (it.next()) : (it.advance()) {
            const console: *Console = @fieldParentPtr("link", it.get());
            write_on(&buf, rec, console);
        }

        console_lock.release();

        cur_seq += 1;
    }

    return cur_seq;
}

fn worker(_: ?*anyopaque) void {
    while (true) {
        _ = ke.wait.wait_one(&ke.log.event.hdr, null) catch unreachable;
        ke.log.event.reset();

        last_seq = drain_from_all(last_seq);
    }
}

pub fn write(buf: []const u8) void {
    console_lock.acquire();

    var it = console_list.iterator();

    while (it.next()) : (it.advance()) {
        const console: *Console = @fieldParentPtr("link", it.get());
        console.write(console.ctx, buf);
    }

    console_lock.release();
}

pub fn register(cons: *Console) void {
    // Drain all logs until now.
    _ = drain_from_on(0, cons);

    console_lock.acquire();
    console_list.insert_tail(&cons.link);
    console_lock.release();
}

pub fn init() void {
    console_list.init();

    const td = ps.thread.create_kernel(ke.Thread.Priority.default, worker, null) catch @panic("handle me");
    ke.sched.enqueue(&td.kern);
}
