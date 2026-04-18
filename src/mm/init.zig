const r = @import("root");
const pl = r.pl;
const mm = r.mm;
const mi = mm.private;
const config = @import("config");

const is_um = @hasDecl(config, "CONFIG_ARCH_UM");

pub const map_kernel = if (!is_um)
    struct {
        extern var text_start_addr: u8;
        extern var text_end_addr: u8;
        extern var rodata_start_addr: u8;
        extern var rodata_end_addr: u8;
        extern var data_start_addr: u8;
        extern var data_end_addr: u8;
        pub fn call(boot_info: *pl.BootInfo) void {
            const kaddr = boot_info.kernel_address;

            const text_start = @intFromPtr(&text_start_addr);
            const text_end = @intFromPtr(&text_end_addr);
            const rodata_start = @intFromPtr(&rodata_start_addr);
            const rodata_end = @intFromPtr(&rodata_end_addr);
            const data_start = @intFromPtr(&data_start_addr);
            const data_end = @intFromPtr(&data_end_addr);

            const text_size = text_end - text_start;
            const rodata_size = rodata_end - rodata_start;
            const data_size = data_end - data_start;

            mi.kernel_pmap.map_contiguous_range(text_start, kaddr.physical_base + (text_start - kaddr.virtual_base), text_size, .{
                .read = true,
                .execute = true,
                .global = true,
            });

            mi.kernel_pmap.map_contiguous_range(rodata_start, kaddr.physical_base + (rodata_start - kaddr.virtual_base), rodata_size, .{
                .read = true,
                .global = true,
            });

            mi.kernel_pmap.map_contiguous_range(data_start, kaddr.physical_base + (data_start - kaddr.virtual_base), data_size, .{
                .read = true,
                .write = true,
                .global = true,
            });

            mi.kernel_pmap.map_contiguous_range(mm.p2v(0), 0, mi.impl.hhdm_minimum_max_address, .{
                .read = true,
                .write = true,
                .global = true,
            });

            // Now go through every usable entry and map to the HHDM every part that isnt covered by [0, hhdm_minimum_max_address).
            // We can't blindly map until the maximum usable physical address because on some CPUs this might cause MCEs.
            // See https://github.com/torvalds/linux/commit/66520ebc2df3fe52eb4792f8101fac573b766baf
            for (0..boot_info.memory_map.entry_count) |i| {
                const entry = boot_info.memory_map.entries[i];

                if ((entry.type != .Free and entry.type != .LoaderReclaimable) or entry.size < mm.page_size) {
                    continue;
                }

                if (entry.base + entry.size <= mi.impl.hhdm_minimum_max_address) {
                    continue;
                }

                var entry_start = entry.base;
                var entry_size = entry.size;

                if (entry.base < mi.impl.hhdm_minimum_max_address) {
                    const adjust = mi.impl.hhdm_minimum_max_address - entry.base;
                    entry_start += adjust;
                    entry_size -= adjust;
                }

                mi.kernel_pmap.map_contiguous_range(mm.p2v(entry_start), entry_start, entry_size, .{
                    .read = true,
                    .write = true,
                    .global = true,
                });
            }
        }
    }.call
else
    struct {
        pub fn call(_: *pl.BootInfo) void {}
    }.call;

pub fn init(boot_info: *pl.BootInfo) linksection(r.init) void {
    mi.phys.init(boot_info);
    map_kernel(boot_info);
    mi.kernel_pmap.activate();
    mi.phys.init_pfndb();
    mi.zone.early_init();
    mi.vmem.init();
    mi.heap.init();
}
