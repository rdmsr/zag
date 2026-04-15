const amd64 = @import("arch");
const int = @import("int.zig");
const b = @import("base");

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

pub fn early_init() linksection(b.init) void {
    const gdtr: amd64.Gdtr = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };

    gdt_load(&gdtr);

    int.init();

    // Enable Per-CPU data for this CPU
    amd64.write_msr(.GsBase, 0);
}
