const amd64 = @import("arch");
const int = @import("int.zig");
const r = @import("root");
const std = @import("std");
const impl = @import("impl.zig");
const ke = r.ke;
const ki = r.ke.private;
const pl = r.pl;

var gdt = extern struct {
    entries: [9]u64 align(1),
    tss: amd64.TssDescriptor align(1),
}{
    .entries = .{
        0, // null
        0x00009a000000ffff, // code16
        0x000093000000ffff, // data16
        0x00cf9a000000ffff, // code32
        0x00cf93000000ffff, // data32
        0x00af9b000000ffff, // kernel code64
        0x00af93000000ffff, // kernel data64
        0x00aff3000000ffff, // user code64
        0x00affb000000ffff, // user data64
    },

    .tss = undefined,
};

extern fn gdt_load(gdtr: *const amd64.Gdtr) callconv(.{ .x86_64_sysv = .{} }) void;

fn early_cpu_init() linksection(r.init) void {
    const gdtr: amd64.Gdtr = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };

    gdt_load(&gdtr);

    var cr0: amd64.Cr0 = @bitCast(amd64.read_cr(0));

    // Disable x87 emulation.
    cr0.em = false;
    // Monitor co-processor.
    cr0.mp = true;
    // Numeric error.
    cr0.ne = true;
    // Write-protection (cannot write to read-only pages).
    cr0.wp = true;

    amd64.write_cr(0, @bitCast(cr0));

    // Enable CPU features we might want through cr4.
    const f = amd64.cpu_features;
    var cr4: amd64.Cr4 = @bitCast(amd64.read_cr(4));

    // Allow userspace to read TSC.
    cr4.tsd = false;
    // Enable global pages.
    cr4.pge = f.pge;

    if (f.fxsave == true) {
        // Enable FXSAVE/FXRSTOR and SSE.
        cr4.osfxsr = true;
        cr4.osxmmexcpt = true;
    }

    // Enable XSAVE.
    cr4.osxsave = f.xsave;

    // Enable UMIP.
    cr4.umip = f.umip;

    amd64.write_cr(4, @bitCast(cr4));

    // Configure the EFER MSR.
    var efer: amd64.Efer = @bitCast(amd64.read_msr(.Efer));

    // Enable syscall if supported.
    efer.sce = f.syscall;
    // Enable NX.
    efer.nxe = true;

    amd64.write_msr(.Efer, @bitCast(efer));

    amd64.sti();
}

pub fn ap_entry(cpu_id: u32, booted: *std.atomic.Value(usize)) noreturn {
    early_cpu_init();
    ki.cpu.init_cpu(cpu_id);
    pl.impl.init_ap();

    _ = booted.fetchAdd(1, .monotonic);

    while (true) {
        std.atomic.spinLoopHint();
    }
}

var initial_offsets: [1]usize = .{0};
extern var __percpu_start: u8;

pub fn early_init() linksection(r.init) void {
    amd64.detect_cpu_features();
    early_cpu_init();

    impl.cpu_offsets = &initial_offsets;

    // Enable Per-CPU data for this CPU
    amd64.write_msr(.GsBase, 0);

    int.init();
}
