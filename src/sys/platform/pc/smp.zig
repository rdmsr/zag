const apic = @import("apic.zig");
const r = @import("root");
const std = @import("std");
const rtl = @import("rtl");
const config = @import("config");
const mm = r.mm;
const ke = r.ke;
const kep = ke.private;
const amd64 = @import("arch");

const log = std.log.scoped(.smp);

extern var AP_TRAMPOLINE_START: u8;
extern var AP_TRAMPOLINE_END: u8;
extern var AP_TRAMPOLINE_DATA: u8;

extern var __percpu_start: u8;
extern var __percpu_end: u8;

pub export var cpu_id_to_apic_id: [config.ncpus]u32 = undefined;

const start_stack = ke.ExportedCpuLocalTypeType(usize, 0, "ap_start_stack");

pub const start_thread = ke.CpuLocalType(*ke.Thread, undefined);

var aps_booted = std.atomic.Value(usize).init(0);

const ApData = extern struct {
    entry: usize align(1),
    cr3: usize align(1),
    idtr: usize align(1),
    xapic_base: usize align(1),
    xapic_virt_base: usize align(1),
};

fn ap_entry(cpu_id: u32) callconv(.c) noreturn {
    kep.impl.init.ap_entry(cpu_id, &aps_booted);
}

fn make_thread(
    stack: usize,
    cpu: u32,
) *ke.Thread {
    const td = mm.zone.gpa.create(ke.Thread) catch
        @panic("Failed to allocate thread for AP");

    td.init(.{
        .stack = stack,
        .priority = .IdleThread,
        .entry = undefined,
        // Shouldn't block.
        .turnstile = undefined,
    });

    td.continuation = null;

    ke.sched.pin_on(td, cpu);
    return td;
}

fn delay_for_cpu() struct { rtl.Duration, rtl.Duration } {
    // From Linux, on modern CPUs we can skip the long delay after INIT.
    const skip_delay = switch (amd64.cpu_features.vendor) {
        .Intel => amd64.cpu_features.family >= 0x06,
        .Amd => amd64.cpu_features.family >= 0x0f,
        .Hygon => amd64.cpu_features.family >= 0x18,
        .Unknown => false,
    };

    const init_delay = rtl.Duration.ms(if (skip_delay) 0 else 10);
    const sipi_delay = rtl.Duration.us(if (skip_delay) 10 else 300);

    return .{ init_delay, sipi_delay };
}

const ap_stack_size = r.kib(16);

pub fn init() linksection(r.init) void {
    const trampoline_start = @intFromPtr(&AP_TRAMPOLINE_START);
    const trampoline_size = @intFromPtr(&AP_TRAMPOLINE_END) - trampoline_start;

    // Map the trampoline page.
    mm.private.kernel_space.pmap.map_contiguous_range(0x8000, 0x8000, 0x1000, .{
        .read = true,
        .write = true,
        .execute = true,
    });

    const init_delay, const sipi_delay = delay_for_cpu();
    const page: [*]u8 = @ptrFromInt(mm.p2v(0x8000));
    const pcpu_start = @intFromPtr(&__percpu_start);

    @memcpy(
        page[0..trampoline_size],
        @as([*]u8, @ptrFromInt(trampoline_start)),
    );

    const data_offset = @intFromPtr(&AP_TRAMPOLINE_DATA) - trampoline_start;
    const data_phys: *ApData = @ptrFromInt(mm.p2v(0x8000 + data_offset));

    const idtr = amd64.sidtr();
    const offsets = mm.zone.gpa.alloc(usize, apic.apics.items.len + 1) catch
        @panic("Failed to allocate AP local data offsets");

    const percpu_size = @intFromPtr(&__percpu_end) - pcpu_start;

    log.info("per-CPU data size: {} bytes", .{percpu_size});

    // Allocate per-cpu offsets for CPU-local data.
    kep.impl.cpu_offsets = @ptrCast(offsets);
    kep.impl.cpu_offsets[0] = 0;
    cpu_id_to_apic_id[0] = apic.get_id();

    // Set up the AP data block.
    data_phys.entry = @intFromPtr(&ap_entry);
    data_phys.cr3 = amd64.read_cr(3);
    data_phys.idtr = @intFromPtr(&idtr);
    data_phys.xapic_base = apic.xapic_base_physical;
    data_phys.xapic_virt_base = mm.p2v(apic.xapic_base_physical);

    for (0..apic.apics.items.len, apic.apics.items) |i, apic_id| {
        const cpu_id: u32 = @as(u32, @intCast(i)) + 1;
        cpu_id_to_apic_id[cpu_id] = apic_id;

        // Allocate per-cpu data.
        const cpu_data = mm.zone.gpa.alloc(u8, percpu_size) catch
            @panic("Failed to allocate per-cpu data");

        @memcpy(
            cpu_data,
            @as([*]u8, @ptrFromInt(pcpu_start))[0..percpu_size],
        );

        const self_offset_offset = @intFromPtr(&kep.impl.cpu_self_offset) -
            pcpu_start;

        kep.impl.cpu_offsets[cpu_id] = @intFromPtr(cpu_data.ptr) -% pcpu_start;

        const off: *usize = @ptrCast(@alignCast(&cpu_data[self_offset_offset]));

        // copy the offset into the AP's self_offset variable
        off.* = kep.impl.cpu_offsets[cpu_id];

        const stack_top = @intFromPtr(mm.heap.alloc(
            ap_stack_size,
            .DontWaitForMemory,
        ) catch
            @panic("Failed to allocate AP stack")) + ap_stack_size;

        start_stack.remote(cpu_id).* = stack_top & ~@as(usize, 15);
        start_thread.remote(cpu_id).* = make_thread(stack_top, cpu_id);

        rtl.barrier.fence(.release);

        // Send the INIT-SIPI-SIPI sequence to start the AP.
        apic.send_init(apic_id);
        ke.time.sleep(init_delay);
        apic.send_sipi(apic_id, 0x08);
        ke.time.sleep(sipi_delay);
        apic.send_sipi(apic_id, 0x08);
    }

    log.info("Waiting for APs...", .{});

    while (aps_booted.load(.acquire) < apic.apics.items.len) {
        std.atomic.spinLoopHint();
    }

    log.info("Booted all APs, total {} CPUs", .{apic.apics.items.len + 1});
    ke.ncpus = apic.apics.items.len + 1;
}
