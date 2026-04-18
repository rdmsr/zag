const b = @import("root");
const mm = b.mm;
const pl = b.pl;
const arch = @import("arch");
const std = @import("std");
const timer = @import("timer.zig");
const hpet = @import("hpet.zig");
pub const madt = @import("madt.zig");

const log = std.log.scoped(.acpi);

const rsdp_signature = "RSD PTR ";
const rsdt_signature = "RSDT";
const xsdt_signature = "XSDT";
const madt_signature = "APIC";
const fadt_signature = "FACP";
const mcfg_signature = "MCFG";
const hpet_signature = "HPET";

pub const AddressSpaceId = enum(u8) {
    SystemMemory = 0,
    SystemIo = 1,
    PciConfigurationSpace = 2,
    EmbeddedController = 3,
    SMBus = 4,
    SystemCMOS = 5,
    PciBarTarget = 6,
    IPMI = 7,
    GeneralPurposeIO = 8,
    GenericSerialBus = 9,
    PlatformCommunicationsChannel = 10,
    FunctionalFixedHardware = 0x7F,
};

pub const Rsdp = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_address: u32 align(1),

    // The following fields are only valid if revision >= 2.
    length: u32 align(1),
    xsdt_address: u64 align(1),
    extended_checksum: u8 align(1),
    reserved: [3]u8 align(1),
};

pub const SdtHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

pub const Rsdt = extern struct {
    header: SdtHeader,
    entries: [0]u32 align(1),
};

pub const Xsdt = extern struct {
    header: SdtHeader,
    entries: [0]u64 align(1),
};

pub const MadtEntryHeader = extern struct {
    const Type = enum(u8) {
        LocalApic = 0,
        IoApic = 1,
        Iso = 2,
        NmiSource = 3,
        LocalApicNmi = 4,
        X2LocalApic = 9,
        X2LocalApicNmi = 10,
    };
    type: Type align(1),
    length: u8 align(1),
};

pub const Madt = extern struct {
    header: SdtHeader,
    lapic_address: u32 align(1),
    flags: u32 align(1),
    entries: [0]MadtEntryHeader align(1),
};

/// Generic address structure.
pub const Gas = extern struct {
    /// The address space where the structure exists.
    address_space_id: AddressSpaceId align(1),
    /// The size in bits of the given register.
    register_bit_width: u8 align(1),
    /// The bit offset of the given register at the given address.
    register_bit_offset: u8 align(1),
    /// The access size of the given register. (1 = byte, 2 = word, 3 = dword, 4 = qword).
    access_size: u8 align(1),
    address: u64 align(1),
    pub fn read(self: Gas) u64 {
        const raw: u64 = switch (self.address_space_id) {
            .SystemMemory => switch (self.access_size) {
                1 => b.mmio_read(u8, self.address),
                2 => b.mmio_read(u16, self.address),
                3 => b.mmio_read(u32, self.address),
                4 => b.mmio_read(u64, self.address),
                else => unreachable,
            },
            .SystemIo => switch (self.access_size) {
                1 => arch.pio_read(u8, @truncate(self.address)),
                2 => arch.pio_read(u16, @truncate(self.address)),
                3 => arch.pio_read(u32, @truncate(self.address)),
                else => unreachable,
            },
            else => @panic("unsupported GAS address space"),
        };

        const shifted = raw >> @intCast(self.register_bit_offset);
        const mask = if (self.register_bit_width == 64)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(self.register_bit_width)) - 1;
        return shifted & mask;
    }

    pub fn write(self: Gas, value: u64) void {
        const masked_value = value & if (self.register_bit_width == 64)
            std.math.maxInt(u64)
        else
            (@as(u64, 1) << @intCast(self.register_bit_width)) - 1;
        const shifted_value = masked_value << self.register_bit_offset;

        switch (self.address_space_id) {
            .SystemMemory => switch (self.access_size) {
                1 => b.mmio_write(u8, self.address, @truncate(shifted_value)),
                2 => b.mmio_write(u16, self.address, @truncate(shifted_value)),
                3 => b.mmio_write(u32, self.address, @truncate(shifted_value)),
                4 => b.mmio_write(u64, self.address, shifted_value),
                else => unreachable,
            },
            .SystemIo => switch (self.access_size) {
                1 => arch.pio_write(u8, @truncate(self.address), @truncate(shifted_value)),
                2 => arch.pio_write(u16, @truncate(self.address), @truncate(shifted_value)),
                3 => arch.pio_write(u32, @truncate(self.address), @truncate(shifted_value)),
                else => unreachable,
            },
            else => @panic("unsupported GAS address space"),
        }
    }
};

pub const Fadt = extern struct {
    header: SdtHeader,
    firmware_ctrl: u32 align(1),
    dsdt: u32 align(1),
    reserved: u8 align(1),
    preferred_pm_profile: u8 align(1),
    sci_interrupt: u16 align(1),
    smi_command_port: u32 align(1),
    acpi_enable: u8 align(1),
    acpi_disable: u8 align(1),
    s4bios_req: u8 align(1),
    pstate_control: u8 align(1),
    pm1a_evt_blk: u32 align(1),
    pm1b_evt_blk: u32 align(1),
    pm1a_cnt_blk: u32 align(1),
    pm1b_cnt_blk: u32 align(1),
    pm2_cnt_blk: u32 align(1),
    pm_tmr_blk: u32 align(1),
    gpe0_blk: u32 align(1),
    gpe1_blk: u32 align(1),
    pm1_evt_len: u8 align(1),
    pm1_cnt_len: u8 align(1),
    pm2_cnt_len: u8 align(1),
    pm_tmr_len: u8 align(1),
    gpe0_blk_len: u8 align(1),
    gpe1_blk_len: u8 align(1),
    gpe1_base: u8 align(1),
    cst_cnt: u8 align(1),
    p_lvl2_lat: u16 align(1),
    p_lvl3_lat: u16 align(1),
    flush_size: u16 align(1),
    flush_stride: u16 align(1),
    duty_offset: u8 align(1),
    duty_width: u8 align(1),
    day_alarm: u8 align(1),
    month_alarm: u8 align(1),
    century: u8 align(1),
    iapc_boot_arch: u16 align(1),
    reserved2: u8 align(1),
    flags: u32 align(1),
    reset_reg: Gas,
    reset_value: u8 align(1),
    arm_boot_arch: u16 align(1),
    fadt_minor_version: u8 align(1),
    x_firmware_ctrl: u64 align(1),
    x_dsdt: u64 align(1),
    x_pm1a_evt_blk: Gas,
    x_pm1b_evt_blk: Gas,
    x_pm1a_cnt_blk: Gas,
    x_pm1b_cnt_blk: Gas,
    x_pm2_cnt_blk: Gas,
    x_pm_tmr_blk: Gas,
    x_gpe0_blk: Gas,
    x_gpe1_blk: Gas,
    sleep_control_reg: Gas,
    sleep_status_reg: Gas,
    hypervisor_vendor_id: [8]u8 align(1),

    const version_sizes = [_]usize{ 116, 132, 244, 244, 268, 276 };

    pub fn revision(self: Fadt) u8 {
        // We can't rely on firmware to set the revision field correctly, so we infer it from the length field.
        const declared: usize = self.header.revision;
        const len: u32 = self.header.length;

        const idx = for (version_sizes, 0..) |size, i| {
            if (len <= size) break i;
        } else version_sizes.len;

        const inferred: usize = @min(idx + 1, version_sizes.len);

        if (declared == inferred or (inferred == 3 and declared == 4)) {
            return @intCast(declared);
        }

        return @intCast(inferred);
    }
};

pub const HpetTable = extern struct {
    hdr: SdtHeader,
    hardware_rev_id: u8 align(1),
    bits: packed struct(u8) {
        comparator_count: u5,
        counter_size_capability: u1,
        reserved: u1,
        legacy_replacement_capability: u1,
    } align(1),
    pci_vendor_id: u16 align(1),
    base_address: Gas,
    hpet_number: u8 align(1),
    minimum_tick: u16 align(1),
    page_protection: u8 align(1),
};

pub const HpetRegs = extern struct {
    general_capabilities: u64,
    reserved0: u64,
    general_configuration: u64,
    reserved1: u64,
    general_interrupt_status: u64,
    reserved2: [25]u64,
    main_counter_value: u64,
};

pub var xsdt: ?*Xsdt = null;
pub var rsdt: ?*Rsdt = null;

pub fn find_table(signature: []const u8) ?*SdtHeader {
    if (xsdt) |x| {
        const entry_count = (x.header.length - @sizeOf(SdtHeader)) / @sizeOf(u64);
        const entries_ptr: [*]align(1) u64 = @ptrCast(&x.entries);

        for (0..entry_count) |i| {
            const hdr: *SdtHeader = @ptrFromInt(mm.p2v(entries_ptr[i]));
            if (std.mem.eql(u8, hdr.signature[0..], signature)) {
                return hdr;
            }
        }
    } else if (rsdt) |r| {
        const entry_count = (r.header.length - @sizeOf(SdtHeader)) / @sizeOf(u32);
        const entries_ptr: [*]align(1) u32 = @ptrCast(&r.entries);

        for (0..entry_count) |i| {
            const hdr: *SdtHeader = @ptrFromInt(mm.p2v(entries_ptr[i]));
            if (std.mem.eql(u8, hdr.signature[0..], signature)) {
                return hdr;
            }
        }
    }

    return null;
}

fn format_table(hdr: *SdtHeader, phys_addr: u64) void {
    log.info("{s} 0x{x:0>16} {x:0>6} (v{d:0>2} {s} {s} {x:0>8} {s} {x:0>8})", .{
        hdr.signature,
        phys_addr,
        hdr.length,
        hdr.revision,
        std.mem.trimEnd(u8, &hdr.oem_id, " "),
        std.mem.trimEnd(u8, &hdr.oem_table_id, " "),
        hdr.oem_revision,
        std.mem.asBytes(&hdr.creator_id),
        hdr.creator_revision,
    });
}

fn enumerate_tables() void {
    if (xsdt) |x| {
        const entry_count = (x.header.length - @sizeOf(SdtHeader)) / @sizeOf(u64);
        const entries_ptr: [*]align(1) u64 = @ptrCast(&x.entries);

        for (0..entry_count) |i| {
            const phys = entries_ptr[i];
            const hdr: *SdtHeader = @ptrFromInt(mm.p2v(phys));
            format_table(hdr, phys);
        }
    } else if (rsdt) |r| {
        const entry_count = (r.header.length - @sizeOf(SdtHeader)) / @sizeOf(u32);
        const entries_ptr: [*]align(1) u32 = @ptrCast(&r.entries);

        for (0..entry_count) |i| {
            const phys: u64 = entries_ptr[i];
            const hdr: *SdtHeader = @ptrFromInt(mm.p2v(phys));
            format_table(hdr, phys);
        }
    }
}

pub fn init(boot_info: *pl.BootInfo) linksection(b.init) void {
    const rsdp_addr = boot_info.rsdp orelse return;

    const rsdp: *Rsdp = @ptrFromInt(rsdp_addr);

    if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
        xsdt = @ptrFromInt(mm.p2v(rsdp.xsdt_address));
        log.info("XSDT found at {x:0>16}", .{rsdp.xsdt_address});
    } else {
        rsdt = @ptrFromInt(mm.p2v(rsdp.rsdt_address));
        log.info("RSDT found at {x:0>16}", .{rsdp.rsdt_address});
    }

    enumerate_tables();

    // Try getting the HPET first so we don't initialize
    // the legacy timer if we have a better option.
    const hpet_t = find_table(hpet_signature);
    if (hpet_t) |h| {
        const hpet_struct: *HpetTable = @ptrCast(h);
        hpet.init(hpet_struct);
    }

    const fadt = find_table(fadt_signature);
    if (fadt) |f| {
        const fadt_struct: *Fadt = @ptrCast(f);
        timer.init(fadt_struct);
    }

    const madt_t = find_table(madt_signature);
    if (madt_t) |m| {
        madt.madt_ptr = @ptrCast(m);
    }
}
