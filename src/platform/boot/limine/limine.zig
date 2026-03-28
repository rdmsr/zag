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

pub fn baseRevision(rev: u64) [3]u64 {
    return .{
        0xf9562b2d5c95a6c8,
        0x6a7b384944536bdc,
        rev,
    };
}

pub fn baseRevisionSupported(base_rev: *const [3]u64) bool {
    // Limine will overwrite base_rev[2] with 0 if it supports the requested revision.
    return base_rev[2] == 0;
}

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
    // Response revision 1 fields (ignored by this template).
    mode_count: u64,
    modes: ?[*]*anyopaque,
};

