const std = @import("std");

const r = @import("root");

const pl = r.pl;
const ke = r.ke;
const ki = ke.private;

pub const std_options = r.std_options;
pub const panic = r.panic;

export fn kmain(info: *r.BootInfo) callconv(.c) void {
    ke.ncpus = 1;

    ki.init(info);
}
