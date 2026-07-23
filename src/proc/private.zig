const r = @import("root");
const ke = r.ke;
const ki = ke.private;
const mm = r.mm;

pub const thread = @import("thread.zig");

pub var turnstile_zone: mm.zone.TypedZone(ki.turnstile.Turnstile) = undefined;

fn turnstile_ctor(ts: *ki.turnstile.Turnstile) void {
    ts.* = .{
        .link = undefined,
        .next_free = null,
        .obj = undefined,
        .queues = undefined,
        .waiters = 0,
        .owners = .none,
    };
    ts.reset();
}

/// Initialize the process subsystem.
pub fn init() void {
    turnstile_zone.init("turnstiles", .{ .ctor = turnstile_ctor });
    thread.init();
}
