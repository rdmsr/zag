//! Wrappers over amd64 CPU instructions and CPUID feature detection.
const std = @import("std");

pub const Msr = enum(u32) {
    /// IA32_APIC_BASE
    LapicBase = 0x1B,
    /// IA32_FS_BASE
    FsBase = 0xC000_0100,
    /// IA32_GS_BASE
    GsBase = 0xC000_0101,
    /// IA32_KERNEL_GS_BASE
    KernelGsBase = 0xC000_0102,
    /// IA32_EFER
    Efer = 0xC000_0080,
    /// IA32_STAR
    Star = 0xC000_0081,
    /// IA32_LSTAR
    LStar = 0xC000_0082,
};

pub const InterruptFrame = packed struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    intno: u64,
    errcode: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub inline fn rdmsr(msr: Msr) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (@intFromEnum(msr)),
    );
    return @as(u64, high) << 32 | low;
}

pub inline fn wrmsr(msr: Msr, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
          [msr] "{ecx}" (@intFromEnum(msr)),
    );
}

pub inline fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true });
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub inline fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
    );
    return @as(u64, high) << 32 | low;
}

pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

pub inline fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

pub const CpuidRequest = union(enum) {
    vendor_info,
    feature_info,
    extended_info,
    highest_extended_function,
    extended_features: ExtendedFeaturesSubLeaf,
    brand_string: BrandStringPart,
    power_management_info,

    pub const ExtendedFeaturesSubLeaf = enum(u32) {
        first = 0,
        second = 1,
        third = 3,
    };

    pub const BrandStringPart = enum(u32) {
        part0 = 0x80000002,
        part1 = 0x80000003,
        part2 = 0x80000004,
    };

    pub fn execute(self: CpuidRequest) CpuidResult {
        const leaf, const subleaf = switch (self) {
            .vendor_info => .{ 0x0, 0 },
            .feature_info => .{ 0x1, 0 },
            .highest_extended_function => .{ 0x80000000, 0 },
            .extended_info => .{ 0x80000001, 0 },
            .power_management_info => .{ 0x80000007, 0 },
            .extended_features => |s| .{ 0x7, @intFromEnum(s) },
            .brand_string => |p| .{ @intFromEnum(p), 0 },
        };
        return cpuid(leaf, subleaf);
    }
};

const FeatureInfoEcx = packed struct(u32) {
    sse3: bool,
    pclmul: bool,
    dtes64: bool,
    monitor: bool,
    ds_cpl: bool,
    vmx: bool,
    smx: bool,
    est: bool,
    tm2: bool,
    ssse3: bool,
    cnxt_id: bool,
    sdbg: bool,
    fma: bool,
    cx16: bool,
    xtpr: bool,
    pdcm: bool,
    _reserved: u1,
    pcid: bool,
    dca: bool,
    sse4_1: bool,
    sse4_2: bool,
    x2apic: bool,
    movbe: bool,
    popcnt: bool,
    tsc_deadline: bool,
    aes: bool,
    xsave: bool,
    osxsave: bool,
    avx: bool,
    f16c: bool,
    rdrand: bool,
    hypervisor: bool,
};

const FeatureInfoEdx = packed struct(u32) {
    fpu: bool,
    vme: bool,
    de: bool,
    pse: bool,
    tsc: bool,
    msr: bool,
    pae: bool,
    mce: bool,
    cx8: bool,
    apic: bool,
    _reserved0: u1,
    sep: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    psn: bool,
    clfsh: bool,
    _reserved1: u1,
    ds: bool,
    acpi: bool,
    mmx: bool,
    fxsave: bool,
    sse: bool,
    sse2: bool,
    ignore: u5,
};

const ExtendedFeaturesEcx = packed struct(u32) {
    _reserved0: u16,
    la57: bool,
    _reserved1: u5,
    rdpid: bool,
    _reserved2: u9,
};

const ExtendedFeaturesEbx = packed struct(u32) {
    ignore: u7,
    smep: bool,
    ignore2: u12,
    smap: bool,
    ignore3: u11,
};

const ExtendedProcessorInfoEdx = packed struct(u32) {
    ignore: u20,
    nx: bool,
    ignore2: u5,
    pdpe1gb: bool,
    ignore3: u5,
};

const PowerManagementInfoEdx = packed struct(u32) {
    ignore: u8,
    invtsc: bool,
    ignore2: u23,
};

fn assert_bit(comptime T: type, comptime field_name: []const u8, comptime expected_bit: u5) void {
    var v: T = @bitCast(@as(u32, 0));
    @field(v, field_name) = true;
    const raw: u32 = @bitCast(v);
    const want = (@as(u32, 1) << expected_bit);
    if (raw != want) @compileError("bit mismatch for field " ++ field_name);
}

comptime {
    assert_bit(FeatureInfoEcx, "pcid", 17);
    assert_bit(FeatureInfoEcx, "x2apic", 21);
    assert_bit(FeatureInfoEcx, "tsc_deadline", 24);
    assert_bit(FeatureInfoEcx, "xsave", 26);
    assert_bit(ExtendedFeaturesEcx, "la57", 16);
    assert_bit(ExtendedProcessorInfoEdx, "nx", 20);
    assert_bit(ExtendedProcessorInfoEdx, "pdpe1gb", 26);
    assert_bit(PowerManagementInfoEdx, "invtsc", 8);
    assert_bit(FeatureInfoEdx, "fxsave", 24);
    assert_bit(ExtendedFeaturesEbx, "smap", 20);
    assert_bit(ExtendedFeaturesEbx, "smep", 7);
}

pub const CpuFeatures = struct {
    x2apic: bool,
    five_level_paging: bool,
    gib_pages: bool,
    tsc_deadline: bool,
    fxsave: bool,
    xsave: bool,
    invariant_tsc: bool,
    nx: bool,
    pcid: bool,
    smap: bool,
    smep: bool,
    vendor_string: [12]u8,
    brand_string: [48]u8,
};

pub var cpu_features: CpuFeatures = undefined;

pub fn detect_cpu_features() void {
    const vendor_info = CpuidRequest.execute(.vendor_info);
    const max_ext = CpuidRequest.execute(.highest_extended_function).eax;

    const max_basic = vendor_info.eax;

    var x2apic = false;
    var five_level_paging = false;
    var gib_pages = false;
    var tsc_deadline = false;
    var xsave = false;
    var fxsave = false;
    var invtsc = false;
    var nx = false;
    var pcid = false;
    var smap = false;
    var smep = false;

    var vendor_string: [12]u8 = undefined;
    var brand_string: [48]u8 = undefined;

    std.mem.writeInt(u32, vendor_string[0..4], vendor_info.ebx, .little);
    std.mem.writeInt(u32, vendor_string[4..8], vendor_info.edx, .little);
    std.mem.writeInt(u32, vendor_string[8..12], vendor_info.ecx, .little);

    if (max_basic >= 0x1) {
        const r = CpuidRequest.execute(.feature_info);
        const ecx: FeatureInfoEcx = @bitCast(r.ecx);
        const edx: FeatureInfoEdx = @bitCast(r.edx);

        x2apic = ecx.x2apic;
        tsc_deadline = ecx.tsc_deadline;
        xsave = ecx.xsave;
        pcid = ecx.pcid;
        fxsave = edx.fxsave;
    }

    if (max_basic >= 0x7) {
        const r = CpuidRequest.execute(.{ .extended_features = .first });
        const ecx: ExtendedFeaturesEcx = @bitCast(r.ecx);
        const ebx: ExtendedFeaturesEbx = @bitCast(r.ebx);
        smap = ebx.smap;
        smep = ebx.smep;
        five_level_paging = ecx.la57;
    }

    if (max_ext >= 0x80000001) {
        const r = CpuidRequest.execute(.extended_info);
        const edx: ExtendedProcessorInfoEdx = @bitCast(r.edx);
        gib_pages = edx.pdpe1gb;
        nx = edx.nx;
    }

    if (max_ext >= 0x80000004) {
        const parts = [_]CpuidResult{
            CpuidRequest.execute(.{ .brand_string = .part0 }),
            CpuidRequest.execute(.{ .brand_string = .part1 }),
            CpuidRequest.execute(.{ .brand_string = .part2 }),
        };

        var off: usize = 0;
        for (parts) |p| {
            for ([_]u32{ p.eax, p.ebx, p.ecx, p.edx }) |reg| {
                const dst: *[4]u8 = @ptrCast(brand_string[off..].ptr);
                std.mem.writeInt(u32, dst, reg, .little);
                off += 4;
            }
        }
    }

    if (max_ext >= 0x80000007) {
        const r = CpuidRequest.execute(.power_management_info);
        const edx: PowerManagementInfoEdx = @bitCast(r.edx);
        invtsc = edx.invtsc;
    }

    cpu_features = .{
        .x2apic = x2apic,
        .five_level_paging = five_level_paging,
        .gib_pages = gib_pages,
        .tsc_deadline = tsc_deadline,
        .fxsave = fxsave,
        .xsave = xsave,
        .invariant_tsc = invtsc,
        .nx = nx,
        .pcid = pcid,
        .smap = smap,
        .smep = smep,
        .vendor_string = vendor_string,
        .brand_string = brand_string,
    };
}
