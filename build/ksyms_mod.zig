pub const KSym = extern struct {
    addr: u64,
    name_ptr: [*]const u8,
    name_len: usize,
};

extern const ksyms_array: [0]KSym;
extern const ksyms_count: usize;

pub fn get_symbols() []const KSym {
    const ptr = @as([*]const KSym, @ptrCast(&ksyms_array));
    return ptr[0..ksyms_count];
}
