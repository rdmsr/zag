const r = @import("root");
const pl = r.pl;
const mm = r.mm;
const mmp = mm.private;
const config = @import("config");

pub fn init() linksection(r.init) void {
    mmp.phys.init();
    mmp.zone.early_init();
    mmp.vmem.init();
    mmp.heap.init();
}

pub fn late_init() linksection(r.init) void {
    mmp.zone.late_init();
    mmp.tlb.init();
    mmp.balance.init();
}
