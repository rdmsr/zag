const apic = @import("apic.zig");
const b = @import("base");
const std = @import("std");
const rtl = @import("rtl");
const config = @import("config");
const mm = b.mm;
const ke = b.ke;
const ki = ke.private;
const amd64 = @import("arch");

const log = std.log.scoped(.smp);

extern var AP_TRAMPOLINE_START: u8;
extern var AP_TRAMPOLINE_END: u8;
extern var AP_TRAMPOLINE_DATA: u8;

extern var __percpu_start: u8;
extern var __percpu_end: u8;

export var cpu_id_to_apic_id: [config.CONFIG_NCPUS]u32 = undefined;

const start_stack = ke.ExportedCpuLocal(usize, 0, "ap_start_stack");

var aps_booted: std.atomic.Value(usize) = .init(0);

const ApData = extern struct {
    entry: usize align(1),
    cr3: usize align(1),
    idtr: usize align(1),
    xapic_base: usize align(1),
    xapic_virt_base: usize align(1),
};

fn ap_entry(cpu_id: u32) callconv(.c) noreturn {
    _ = aps_booted.fetchAdd(1, .monotonic);
    ki.impl.init.ap_entry(cpu_id);
}

pub fn init() linksection(b.init) void {
    const trampoline_start = @intFromPtr(&AP_TRAMPOLINE_START);
    const trampoline_size = @intFromPtr(&AP_TRAMPOLINE_END) - trampoline_start;

    // Map the trampoline page.
    mm.private.kernel_pmap.map_contiguous_range(0x8000, 0x8000, 0x1000, .{
        .read = true,
        .write = true,
        .execute = true,
    });

    // From Linux, on modern CPUs we can skip the long delay after INIT.
    const skip_delay = switch (amd64.cpu_features.vendor) {
        .Intel => amd64.cpu_features.family >= 0x06,
        .Amd => amd64.cpu_features.family >= 0x0f,
        .Hygon => amd64.cpu_features.family >= 0x18,
        .Unknown => false,
    };

    const init_delay: usize = if (skip_delay) 0 else std.time.ns_per_ms * 10;
    const sipi_delay: usize = if (skip_delay) std.time.ns_per_us * 10 else std.time.ns_per_us * 300;

    const page: [*]u8 = @ptrFromInt(mm.p2v(0x8000));
    @memcpy(page[0..trampoline_size], @as([*]u8, @ptrFromInt(trampoline_start)));

    const data_offset = @intFromPtr(&AP_TRAMPOLINE_DATA) - trampoline_start;
    const data_phys: *ApData = @ptrFromInt(mm.p2v(0x8000 + data_offset));

    const idtr = amd64.sidtr();

    // Allocate per-cpu offsets for CPU-local data.
    ki.impl.cpu_offsets = @ptrCast(mm.zone.gpa.alloc(usize, apic.apics.items.len + 1) catch @panic("Failed to allocate AP local data offsets"));
    const percpu_size = @intFromPtr(&__percpu_end) - @intFromPtr(&__percpu_start);

    ki.impl.cpu_offsets[0] = @intFromPtr(&__percpu_start);

    cpu_id_to_apic_id[0] = apic.get_id();

    // Set up the AP data block.
    data_phys.entry = @intFromPtr(&ap_entry);
    data_phys.cr3 = amd64.read_cr(3);
    data_phys.idtr = @intFromPtr(&idtr);
    data_phys.xapic_base = apic.xapic_base_physical;
    data_phys.xapic_virt_base = mm.p2v(apic.xapic_base_physical);

    for (0..apic.apics.items.len, apic.apics.items) |i, apic_id| {
        const cpu_id = i + 1;
        cpu_id_to_apic_id[cpu_id] = apic_id;

        // Allocate per-cpu data.
        const cpu_data = mm.zone.gpa.alloc(u8, percpu_size) catch @panic("Failed to allocate per-cpu data");
        @memcpy(cpu_data, @as([*]u8, @ptrCast(&__percpu_start))[0..percpu_size]);

        ki.impl.cpu_offsets[cpu_id] = @intFromPtr(cpu_data.ptr) -% @intFromPtr(&__percpu_start);

        const stack_top = @intFromPtr(mm.heap.alloc(b.kib(16)) catch @panic("Failed to allocate AP stack")) + b.kib(16);

        start_stack.remote(@intCast(cpu_id)).* = stack_top & ~@as(usize, 15);

        rtl.barrier.wmb();

        // Send the INIT-SIPI-SIPI sequence to start the AP.
        apic.send_init(apic_id);

        ke.time.sleep(init_delay);
        apic.send_sipi(apic_id, 0x08);
        ke.time.sleep(sipi_delay);
        apic.send_sipi(apic_id, 0x08);
    }

    while (aps_booted.load(.acquire) < apic.apics.items.len) {
        std.atomic.spinLoopHint();
    }

    log.info("Booted all APs, total {} CPUs", .{apic.apics.items.len + 1});
    ke.ncpus = apic.apics.items.len + 1;
}
