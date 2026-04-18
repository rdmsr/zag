const r = @import("root");
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const c = r.pl.impl.c;
const ke = r.ke;
const ki = ke.private;

threadlocal var timerid: c.timer_t = undefined;

fn timer_handler(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const old_ipl = ke.ipl.set_hardware(.Device);

    ki.timer.clock();

    _ = ke.ipl.set_hardware(old_ipl);

    if (@intFromEnum(old_ipl) < @intFromEnum(ke.Ipl.Dispatch) and ki.ipl.is_softint_pending(.Dispatch)) {
        ki.dpc.dispatch(ke.cpu.current());
    }
}

pub fn arm_timer(ns: r.Nanoseconds) void {
    const value: c.struct_itimerspec = .{ .it_value = .{
        .tv_sec = @intCast(ns / std.time.ns_per_s),
        .tv_nsec = @intCast(ns % std.time.ns_per_s),
    }, .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 } };

    if (c.timer_settime(timerid, 0, &value, null) == -1) {
        @panic("timer_settime failed");
    }
}

fn tc_read() u64 {
    var ts: std.c.timespec = undefined;

    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);

    return @intCast(ts.sec * std.time.ns_per_s + ts.nsec);
}

var tc: ke.TimeCounter = .{
    .read_count = tc_read,
    .frequency = std.time.ns_per_s,
    .name = "CLOCK_MONOTONIC",
    .quality = 1000,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

pub fn init() void {
    var act = std.mem.zeroes(posix.Sigaction);

    act.handler.sigaction = timer_handler;
    act.flags = posix.SA.RESTART | posix.SA.SIGINFO;

    act.mask = posix.sigfillset();

    posix.sigaction(posix.SIG.ALRM, &act, null);

    ke.time.register_source(&tc);
}

pub fn init_cpu() void {
    var sev: c.sigevent = std.mem.zeroes(c.sigevent);

    sev.sigev_notify = c.SIGEV_THREAD_ID;
    sev.sigev_signo = c.SIGALRM;
    sev._sigev_un._tid = linux.gettid();

    if (c.timer_create(c.CLOCK_MONOTONIC, &sev, &timerid) == -1) {
        @panic("timer_create failed");
    }
}
