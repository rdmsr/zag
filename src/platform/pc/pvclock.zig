const amd64 = @import("arch");
const kvm = amd64.hypervisor.kvm;
const r = @import("root");
const std = @import("std");
const mm = r.mm;
const ke = r.ke;

var pvclock_src: kvm.PVClockSource = undefined;
var pvclock_tc: ke.TimeCounter = .{
    .name = "pvclock",
    .quality = 75,
    .frequency = std.time.ns_per_s,
    .read_count = read_pvclock,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

pub fn init() linksection(r.init) void {
    const page = mm.phys.alloc();
    pvclock_src = kvm.PVClockSource.init(page, mm.p2v(page));
    ke.time.register_source(&pvclock_tc);
}

fn read_pvclock() u64 {
    return pvclock_src.read();
}
