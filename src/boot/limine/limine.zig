pub const common_magic: [2]u64 = .{
    0xc7b1dd30df4c8b88,
    0x0a82e883a194f07b,
};

pub const requests_start_marker: [4]u64 = .{
    0xf6b8f4b39de7d1ae,
    0xfab91a6940fcb9cf,
    0x785c6ed015d3e316,
    0x181e920a7852b9d9,
};

pub const requests_end_marker: [2]u64 = .{
    0xadc0e0531bb10d03,
    0x9572709f31764c62,
};

pub fn base_revision(rev: u64) [3]u64 {
    return .{
        0xf9562b2d5c95a6c8,
        0x6a7b384944536bdc,
        rev,
    };
}

pub fn base_revision_supported(base_rev: *const [3]u64) bool {
    return base_rev[2] == 0;
}

pub const memmap_request_id: [4]u64 = .{
    common_magic[0],
    common_magic[1],
    0x67cf3d9d378a806f,
    0xe304acdfc50c3c62,
};

pub const MemmapRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*MemmapResponse,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: ?[*]*MemmapEntry,
};

pub const MemmapEntryType = enum(u64) {
    Usable = 0,
    Reserved = 1,
    AcpiReclaimable = 2,
    AcpiNvs = 3,
    BadMemory = 4,
    BootloaderReclaimable = 5,
    KernelAndModules = 6,
    Framebuffer = 7,
    ReservedMapped = 8,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemmapEntryType,
};

pub const rsdp_request_id: [4]u64 = .{
    common_magic[0],
    common_magic[1],
    0xc5e77b6b397e7b43,
    0x27637845accdcf3c,
};

pub const RsdpRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*RsdpResponse,
};

pub const RsdpResponse = extern struct {
    revision: u64,
    rsdp: ?*anyopaque,
};

pub const cmdline_request_id: [4]u64 = .{
    common_magic[0],
    common_magic[1],
    0x4b161536e598651e,
    0xb390ad4a2f1f303a,
};

pub const CmdlineRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*CmdlineResponse,
};

pub const CmdlineResponse = extern struct {
    revision: u64,
    cmdline: ?[*:0]u8,
};

pub const executable_address_request_id: [4]u64 = .{
    common_magic[0],
    common_magic[1],
    0x71ba76863cc55f63,
    0xb2644a48c516a487,
};

pub const ExecutableAddressRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*ExecutableAddressResponse,
};

pub const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const framebuffer_request_id: [4]u64 = .{
    common_magic[0],
    common_magic[1],
    0x9d5827dcd881dd75,
    0xa3148604f6fab11b,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*FramebufferResponse,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: ?[*]*Framebuffer,
};

pub const Framebuffer = extern struct {
    address: ?*anyopaque,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
};
