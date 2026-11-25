//! Initialization of the executive.

const std = @import("std");
const r = @import("root");
const pl = r.pl;
const ke = r.ke;
const mm = r.mm;
const ex = r.ex;
const ps = r.ps;
const exp = ex.private;
const rtl = @import("rtl");
const dst = @import("dst");
const config = @import("config");

pub fn init() void {
    exp.vmem.init();
    mm.init();
    ps.init();

    pl.late_init();
    mm.late_init();
    ke.sched.late_init();

    exp.work.init() catch @panic("e");
    exp.string.init();

    if (config.dst) {
        const cline = r.boot_info.cmdline orelse @panic("dst: no cmdline");
        const seed = rtl.cmdline.get_number(u64, cline, "seed") catch {
            @panic("dst: no seed specified");
        };

        dst.init(seed);
        dst.log.info("initialized with seed {x}", .{seed});
        dst.enable();
    }

    if (r.boot_info.cmdline) |cline| {
        if (rtl.cmdline.get_string(cline, "test")) |tst| {
            // Run a test if specified.
            if (r.tests.tests.get(tst)) |func| {
                const t = ps.thread.create_kernel(
                    .Default,
                    .{ .func = func, .arg = r.boot_info },
                    true,
                ) catch
                    @panic("oom");
                ke.sched.enqueue(&t.kern);
            } else {
                std.log.info("invalid test: \"{s}\"", .{tst});
            }
        }
    }
}
