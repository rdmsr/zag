const r = @import("root");
const pl = r.pl;
const mm = r.mm;
const mi = mm.private;
const config = @import("config");

pub fn init() linksection(r.init) void {
    mi.phys.init();
    mi.zone.early_init();
    mi.vmem.init();
    mi.heap.init();
}

pub fn late_init() linksection(r.init) void {
    mi.zone.late_init();
    mi.tlb.init();
}
