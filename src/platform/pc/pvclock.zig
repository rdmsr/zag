const amd64 = @import("arch");
const kvm = amd64.hypervisor.kvm;
const r = @import("root");
const std = @import("std");
const mm = r.mm;
const ke = r.ke;

var pvclock_src: kvm.PVClockSource = undefined;
var pvclock: ke.ClockSource = .{
    .name = "pvclock",
    .quality = 75,
    .frequency = std.time.ns_per_s,
    .read_count = read_pvclock,
    .mask = std.math.maxInt(u64),
    .p = 0,
    .n = 0,
};

pub fn init() linksection(r.init) void {
    if (ke.clock.is_better_than(&pvclock)) return;
    const page = mm.phys.alloc();
    pvclock_src = kvm.PVClockSource.init(page, mm.p2v(page));
    ke.clock.register_source(&pvclock);
}

fn read_pvclock() u64 {
    return pvclock_src.read();
}
