const b = @import("base");
const ksyms = @import("ksyms");

const pl = b.pl;
const ke = b.ke;
const ki = ke.private;

pub const std_options = b.std_options;
pub const panic = b.panic;

const std = @import("std");

var boot_info: pl.BootInfo = undefined;

export fn kmain() callconv(.c) void {
    boot_info.memory_map.entry_count = 0;

    var cpus: [1]*ke.Cpu = .{&ke.private.bootstrap_cpu};

    ke.ncpus = 1;
    ke.cpus = &cpus;

    ki.init(&boot_info);
}
