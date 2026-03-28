const b = @import("base");
const ksyms = @import("ksyms");

const pl = b.pl;
const ke = b.ke;

pub const std_options = b.std_options;
pub const panic = b.panic;

pub const rtl = @import("rtl");

const std = @import("std");

var boot_info: pl.BootInfo = undefined;

export fn kmain() callconv(.c) void {
    std.log.info("hello from kernel!", .{});

    for (ksyms.ksyms) |sym| {
        std.log.info("  0x{x:0>16} {s}", .{ sym.addr, sym.name });
    }

    boot_info.memory_map.entry_count = 0;

    var cpus: [1]*ke.Cpu = .{&ke.private.bootstrap_cpu};

    ke.ncpus = 1;
    ke.cpus = &cpus;

    ke.private.init(&boot_info);
}
