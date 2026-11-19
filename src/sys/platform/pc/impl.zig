//! Platform implementation for a generic amd64 PC.
const rtl = @import("rtl");
const r = @import("root");
const pl = r.pl;
const amd64 = r.arch;
const kep = r.ke.private;

const fw = @import("firmware");
const fw_cfg = fw.fw_cfg;

const config = @import("config");
const std = @import("std");
const dst = @import("dst");

const tsc = @import("tsc.zig");
const pvclock = @import("pvclock.zig");
pub const apic = @import("apic.zig");
pub const smp = @import("smp.zig");

pub const name: []const u8 = "PC";

const com1 = 0x3F8;
const com2 = 0x2F8;

const log = std.log.scoped(.@"amd64/pc");

fn com_init(addr: u16) linksection(r.init) void {
    amd64.outb(addr + 0x3, 0x80);
    amd64.outb(addr + 0x0, 0x0c);
    amd64.outb(addr + 0x1, 0x00);
    amd64.outb(addr + 0x3, 0x03);
    amd64.outb(addr + 0x2, 0xc7);
    amd64.outb(addr + 0x4, 0x00);
}

fn com1_write(c: u8) void {
    while ((amd64.inb(com1 + 0x5) & 0x20) == 0) {}
    if (c == '\n') {
        amd64.outb(com1, '\r');
    }
    amd64.outb(com1, c);
}

fn com2_write(c: u8) void {
    while ((amd64.inb(com2 + 0x5) & 0x20) == 0) {}
    amd64.outb(com2, c);
}

fn fw_cfg_select(sel: fw_cfg.Selector) void {
    amd64.outw(0x510, sel.value());
}

fn fw_cfg_read(buf: []u8) void {
    for (buf) |*c| {
        c.* = amd64.inb(0x511);
    }
}

const ops: fw_cfg.Ops = .{
    .select_fn = fw_cfg_select,
    .read_fn = fw_cfg_read,
};

fn dst_init() void {
    const cfg = fw_cfg.FwCfg.init(ops) catch {
        @panic("Invalid fw_cfg device");
    };

    var iter = cfg.files();
    var seed_file: ?fw_cfg.File = null;

    while (iter.next()) |file| {
        if (std.mem.eql(u8, file.name_str(), "opt/dst-seed")) {
            seed_file = file;
        }
    }

    var seed_bytes: [8]u8 = undefined;

    if (seed_file) |sf| {
        sf.read(&cfg, std.mem.asBytes(&seed_bytes));
    } else {
        @panic("No opt/dst-seed fw_cfg file found");
    }

    const seed = std.fmt.parseInt(u64, &seed_bytes, 10) catch
        @panic("Invalid seed");

    dst.init(seed);

    dst.log.info("Initialized with seed {x}", .{seed});

    for (0..20) |_| {
        if (dst.buggify(@src())) {
            std.log.info("Here!", .{});
        }
    }

    for (0..20) |_| {
        if (dst.buggify(@src())) {
            std.log.info("Here too!", .{});
        }
    }
}

pub fn early_init() linksection(r.init) void {
    com_init(com1);
    com_init(com2);

    if (config.dst) {
        dst_init();
    }

    const f = amd64.cpu_features;

    log.info("CPU: {s}", .{&f.brand_string});
    log.info("vendor={s} family={x} features={}{}{}{}{}{}{}{}{}{}{}{}", .{
        @tagName(f.vendor),
        f.family,
        @intFromBool(f.x2apic),
        @intFromBool(f.five_level_paging),
        @intFromBool(f.nx),
        @intFromBool(f.pcid),
        @intFromBool(f.pge),
        @intFromBool(f.smap),
        @intFromBool(f.smep),
        @intFromBool(f.gib_pages),
        @intFromBool(f.invariant_tsc),
        @intFromBool(f.xsave),
        @intFromBool(f.fxsave),
        @intFromBool(f.tsc_deadline),
    });

    if (amd64.hypervisor.info) |h| {
        log.info("running on hypervisor {s}", .{@tagName(h.vendor)});
    }
}

fn init_hypervisor(hv: amd64.hypervisor.Info) void {
    switch (hv.data) {
        .KVM => |kvm_info| {
            if (kvm_info.features.clocksource2 == true) {
                pvclock.init();
            }
        },
        else => {},
    }
}

pub fn init_ap() void {
    if (amd64.cpu_features.x2apic) {
        apic.enter_x2apic();
    }
    apic.init_local();
}

pub fn late_init() linksection(r.init) void {
    if (amd64.hypervisor.info) |hv| {
        init_hypervisor(hv);
    }

    pl.acpi.init();

    tsc.init();

    apic.init();

    if (apic.apics.items.len != 0) {
        smp.init();
    }

    if (amd64.cpu_features.x2apic) {
        apic.enter_x2apic();
    }
}

pub fn debug_write(c: u8) void {
    com1_write(c);
}

pub fn debug_read() u8 {
    while ((amd64.inb(com2 + 0x5) & 0x01) == 0) {
        std.atomic.spinLoopHint();
    }
    return amd64.inb(com2);
}

pub fn dbg_write_raw(c: u8) void {
    com2_write(c);
}

pub fn arm_timer(duration: rtl.Duration) void {
    apic.arm_timer(duration);
}

pub fn send_ipi(target_cpu: u32) void {
    apic.send_ipi(smp.cpu_id_to_apic_id[target_cpu], 240, 0);
}
