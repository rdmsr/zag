//! Wrappers over amd64 CPU definitions and CPUID.
const std = @import("std");

pub const hypervisor = @import("hypervisor.zig");

pub const name = "amd64";

pub const Msr = enum(u32) {
    /// IA32_APIC_BASE
    LapicBase = 0x1B,
    X2ApicBase = 0x800,
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
    /// IA32_TSC_DEADLINE
    TscDeadline = 0x6E0,
    /// MSR_KVM_SYSTEM_TIME_NEW
    KvmSystemTimeNew = 0x4B564D01,
    _,
};

pub const Efer = packed struct(u64) {
    sce: bool,
    reserved0: u7,
    lme: bool,
    reserved1: u1,
    lma: bool,
    nxe: bool,
    svme: bool,
    lmsle: bool,
    ffxsr: bool,
    tce: bool,
    reserved2: u1,
    mcommit: bool,
    interruptible_wb: bool,
    uaie: bool,
    reserved3: u44,
};

pub const IrqFrame = extern struct {
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

pub inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return @as(u64, high) << 32 | low;
}

pub inline fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
          [msr] "{ecx}" (msr),
    );
}

pub inline fn read_msr(comptime msr: Msr) u64 {
    return rdmsr(@intFromEnum(msr));
}

pub inline fn write_msr(comptime msr: Msr, value: u64) void {
    wrmsr(@intFromEnum(msr), value);
}

pub inline fn rdgsbase() usize {
    return asm volatile ("rdgsbase %[ret]"
        : [ret] "=r" (-> usize),
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

pub fn pio_read(comptime T: type, port: u16) T {
    if (@sizeOf(T) == 1) {
        return inb(port);
    } else if (@sizeOf(T) == 2) {
        return inw(port);
    } else if (@sizeOf(T) == 4) {
        return inl(port);
    } else {
        @compileError("unsupported pio read size");
    }
}

pub fn pio_write(comptime T: type, port: u16, value: T) void {
    if (@sizeOf(T) == 1) {
        outb(port, @as(u8, value));
    } else if (@sizeOf(T) == 2) {
        outw(port, @as(u16, value));
    } else if (@sizeOf(T) == 4) {
        outl(port, @as(u32, value));
    } else {
        @compileError("unsupported pio write size");
    }
}

pub const RFlags = packed struct(u64) {
    carry: bool,
    reserved0: u1,
    parity: bool,
    reserved1: u1,
    auxiliary: bool,
    reserved2: u1,
    zero: bool,
    sign: bool,
    trap: bool,
    interrupt_enable: bool,
    direction: bool,
    overflow: bool,
    iopl: u2,
    nested_task: bool,
    reserved3: u1,
    resume_: bool,
    virtual_8086_mode: bool,
    alignment_check: bool,
    virtual_interrupt: bool,
    virtual_interrupt_pending: bool,
    id: bool,
    reserved4: u42,
};

pub inline fn rflags() RFlags {
    var flags: u64 = undefined;
    asm volatile ("pushfq; pop %[flags]"
        : [flags] "=r" (flags),
    );
    return @bitCast(flags);
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

pub const Cr0 = packed struct(u64) {
    pe: bool,
    mp: bool,
    em: bool,
    ts: bool,
    et: bool,
    ne: bool,
    reserved0: u10,
    wp: bool,
    reserved1: u1,
    am: bool,
    reserved2: u10,
    nw: bool,
    cd: bool,
    pg: bool,
    reserved3: u32,
};

comptime {
    _ = Cr0;
    _ = Cr4;
}

pub const Cr4 = packed struct(u64) {
    vme: bool,
    pvi: bool,
    tsd: bool,
    de: bool,
    pse: bool,
    pae: bool,
    mce: bool,
    pge: bool,
    pce: bool,
    osfxsr: bool,
    osxmmexcpt: bool,
    umip: bool,
    la57: bool,
    reserved0: u3,
    fsgsbase: bool,
    pcide: bool,
    osxsave: bool,
    reserved1: u1,
    smep: bool,
    smap: bool,
    pke: bool,
    cet: bool,
    reserved2: u40,
};

pub inline fn read_cr(comptime n: u8) u64 {
    comptime std.debug.assert(n != 1);
    return asm volatile (std.fmt.comptimePrint("mov %%cr{}, %[ret]", .{n})
        : [ret] "=r" (-> u64),
    );
}

pub inline fn write_cr(comptime n: u8, value: u64) void {
    comptime std.debug.assert(n != 1);
    asm volatile (std.fmt.comptimePrint("mov %[value], %%cr{}", .{n})
        :
        : [value] "r" (value),
    );
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
    VendorInfo,
    FeatureInfo,
    ExtendedInfo,
    HighestExtendedFunction,
    ExtendedFeatures: ExtendedFeaturesSubLeaf,
    BrandString: BrandStringPart,
    PowerManagementInfo,
    HypervisorId,

    pub const ExtendedFeaturesSubLeaf = enum(u32) {
        First = 0,
        Second = 1,
        Third = 3,
    };

    pub const BrandStringPart = enum(u32) {
        Part0 = 0x80000002,
        Part1 = 0x80000003,
        Part2 = 0x80000004,
    };

    pub fn execute(self: CpuidRequest) CpuidResult {
        const leaf, const subleaf = switch (self) {
            .VendorInfo => .{ 0x0, 0 },
            .FeatureInfo => .{ 0x1, 0 },
            .HighestExtendedFunction => .{ 0x80000000, 0 },
            .ExtendedInfo => .{ 0x80000001, 0 },
            .PowerManagementInfo => .{ 0x80000007, 0 },
            .ExtendedFeatures => |s| .{ 0x7, @intFromEnum(s) },
            .BrandString => |p| .{ @intFromEnum(p), 0 },
            .HypervisorId => .{ 0x40000000, 0 },
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
    reserved0: u1,
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
    reserved0: u1,
    sep: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    psn: bool,
    clfsh: bool,
    reserved1: u1,
    ds: bool,
    acpi: bool,
    mmx: bool,
    fxsave: bool,
    sse: bool,
    sse2: bool,
    reserved2: u5,
};

const ExtendedFeaturesEcx = packed struct(u32) {
    reserved0: u2,
    umip: bool,
    reserved1: u13,
    la57: bool,
    reserved2: u5,
    rdpid: bool,
    reserved3: u9,
};

const ExtendedFeaturesEbx = packed struct(u32) {
    reserved0: u7,
    smep: bool,
    reserved1: u12,
    smap: bool,
    reserved2: u11,
};

const ExtendedProcessorInfoEdx = packed struct(u32) {
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
    reserved0: u1,
    syscall_sysret: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    reserved1: u1,
    mp: bool,
    nx: bool,
    reserved2: u5,
    pdpe1gb: bool,
    rdtscp: bool,
    reserved3: u1,
    lm: bool,
    _3dnowext: bool,
    _3dnow: bool,
};

const PowerManagementInfoEdx = packed struct(u32) {
    reserved0: u8,
    invtsc: bool,
    reserved1: u23,
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

pub const CpuVendor = enum {
    Intel,
    Amd,
    Hygon,
    Unknown,
};

const known_vendors = [_]struct {
    string: *const [12:0]u8,
    vendor: CpuVendor,
}{
    .{ .string = "GenuineIntel", .vendor = .Intel },
    .{ .string = "AuthenticAMD", .vendor = .Amd },
    .{ .string = "HygonGenuine", .vendor = .Hygon },
};

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
    pge: bool,
    syscall: bool,
    umip: bool,
    vendor: CpuVendor,
    family: u8,
    brand_string: [48]u8,
};

pub const HypervisorVendor = enum(u32) {
    Unknown = 0,
    KVM = 1,
};

pub const HypervisorInfo = struct {
    brand_string: [12]u8,
    vendor: HypervisorVendor,
    highest_function: u32,
};

pub var cpu_features: CpuFeatures = undefined;

fn detect_vendor(string: [12]u8) CpuVendor {
    for (known_vendors) |v| {
        if (std.mem.eql(u8, string[0..], v.string[0..])) {
            return v.vendor;
        }
    }
    return .Unknown;
}

pub fn detect_cpu_features() void {
    const vendor_info = CpuidRequest.execute(.VendorInfo);
    const max_ext = CpuidRequest.execute(.HighestExtendedFunction).eax;

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
    var pge = false;
    var hypervisor_flag = false;
    var syscall = false;
    var family: u8 = 0;
    var umip = false;

    var vendor_string: [12]u8 = undefined;
    var brand_string: [48]u8 = undefined;

    std.mem.writeInt(u32, vendor_string[0..4], vendor_info.ebx, .little);
    std.mem.writeInt(u32, vendor_string[4..8], vendor_info.edx, .little);
    std.mem.writeInt(u32, vendor_string[8..12], vendor_info.ecx, .little);

    const vendor = detect_vendor(vendor_string);

    if (max_basic >= 0x1) {
        const r = CpuidRequest.execute(.FeatureInfo);
        const ecx: FeatureInfoEcx = @bitCast(r.ecx);
        const edx: FeatureInfoEdx = @bitCast(r.edx);

        x2apic = ecx.x2apic;
        tsc_deadline = ecx.tsc_deadline;
        xsave = ecx.xsave;
        pcid = ecx.pcid;
        fxsave = edx.fxsave;
        pge = edx.pge;
        hypervisor_flag = ecx.hypervisor;

        const sig = r.eax;
        family = @truncate((sig >> 8) & 0xf);
        if (family == 0xf) {
            family +%= @truncate((sig >> 20) & 0xff);
        }
    }

    if (max_basic >= 0x7) {
        const r = CpuidRequest.execute(.{ .ExtendedFeatures = .First });
        const ecx: ExtendedFeaturesEcx = @bitCast(r.ecx);
        const ebx: ExtendedFeaturesEbx = @bitCast(r.ebx);
        smap = ebx.smap;
        smep = ebx.smep;
        five_level_paging = ecx.la57;
        umip = ecx.umip;
    }

    if (max_ext >= 0x80000001) {
        const r = CpuidRequest.execute(.ExtendedInfo);
        const edx: ExtendedProcessorInfoEdx = @bitCast(r.edx);
        gib_pages = edx.pdpe1gb;
        nx = edx.nx;
        syscall = edx.syscall_sysret;
    }

    if (max_ext >= 0x80000004) {
        const parts = [_]CpuidResult{
            CpuidRequest.execute(.{ .BrandString = .Part0 }),
            CpuidRequest.execute(.{ .BrandString = .Part1 }),
            CpuidRequest.execute(.{ .BrandString = .Part2 }),
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
        const r = CpuidRequest.execute(.PowerManagementInfo);
        const edx: PowerManagementInfoEdx = @bitCast(r.edx);
        invtsc = edx.invtsc;
    }

    if (hypervisor_flag) {
        hypervisor.detect();
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
        .vendor = vendor,
        .brand_string = brand_string,
        .pge = pge,
        .family = family,
        .umip = umip,
        .syscall = syscall,
    };
}

pub const TssDescriptor = extern struct {
    length: u16 align(1),
    base_low: u16 align(1),
    base_mid: u8 align(1),
    access: u8 align(1),
    flags_limit_high: u8 align(1),
    base_high: u8 align(1),
    base_upper: u32 align(1),
    reserved: u32 align(1),
};

pub const Tss = extern struct {
    reserved1: u32 align(1),
    rsp: [3]usize align(1),
    reserved2: u64 align(1),
    ist: [7]usize align(1),
    reserved3: u64 align(1),
    reserved4: u16 align(1),
    iopb: u16 align(1),
};

pub const Gdtr = extern struct {
    limit: u16 align(1),
    base: usize align(1),
};

pub const Idtr = extern struct {
    limit: u16 align(1),
    base: usize align(1),
};

pub fn sidtr() Idtr {
    var idtr: Idtr = undefined;
    asm volatile ("sidt %[idtr]"
        : [idtr] "={memory}" (idtr),
    );
    return idtr;
}

pub const IdtEntry = extern struct {
    offset_low: u16 align(1),
    selector: u16 align(1),
    ist: u8 align(1),
    type_attr: u8 align(1),
    offset_mid: u16 align(1),
    offset_high: u32 align(1),
    reserved: u32 align(1),

    pub const Attr = enum(u8) {
        InterruptGate = 0x8E,
        TrapGate = 0x8F,
    };

    pub fn init(cs: u16, ist: u8, attr: Attr, offset: usize) @This() {
        return .{
            .offset_low = @truncate(offset),
            .selector = cs,
            .ist = ist,
            .type_attr = @intFromEnum(attr),
            .offset_mid = @truncate(offset >> 16),
            .offset_high = @truncate(offset >> 32),
            .reserved = 0,
        };
    }
};
