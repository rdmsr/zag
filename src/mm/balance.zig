//! Balance manager.
//! The balance manager is called periodically (or when memory is low) to do
//! the following actions:
//! 1. Reap unused kernel stacks
//! 2. Zone trimming
//! 3. Working-set trimming (eventually...)

const r = @import("root");
const std = @import("std");
const ps = r.ps;
const ke = r.ke;
const mm = r.mm;
const mmp = mm.private;

const balance_interval = ke.Tunable(u32, 1000, "mm.balance.interval_ms");

const stack_reap_interval = 5;
const zone_update_interval = mm.zone.update_interval_s;

var stack_reap_time: u8 = stack_reap_interval;
var zone_update_time: u8 = zone_update_interval;

pub fn init() void {
    const td = ps.thread.create_kernel(.LowRealtime, .{
        .func = balance_manager,
        .arg = null,
    }, true) catch
        @panic("Could not create balance manager thread");

    ke.sched.enqueue(&td.kern);
}

fn balance_manager(_: ?*anyopaque) void {
    while (true) {
        var timer: ke.Timer = undefined;
        timer.init();
        ke.timer.set(
            &timer,
            .from(r.Milliseconds.init(balance_interval.load())),
            .{},
        );

        _ = ke.wait.wait_one(&timer.hdr, "balmgr", .{}) catch unreachable;

        stack_reap_time -= 1;
        zone_update_time -= 1;

        if (zone_update_time == 0) {
            zone_update_time = zone_update_interval;
            mm.zone.update();
        }

        if (stack_reap_time == 0) {
            stack_reap_time = stack_reap_interval;

            if (ke.thread.stack_cache_update()) |lst| {
                // Reap all the excess stacks.
                var entry: ?*ke.Stack = lst;

                while (entry != null) {
                    const next = entry.?.next;
                    mm.heap.free(
                        (@intFromPtr(entry) + @sizeOf(ke.Stack)) - ps.thread.kernel_thread_stack_size,
                        ps.thread.kernel_thread_stack_size,
                    );
                    entry = next;
                }
            }
        }
    }
}
