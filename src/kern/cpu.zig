const config = @import("config");
const rtl = @import("rtl");
const r = @import("root");

const ke = r.ke;
const ki = r.ke.private;

const id = CpuLocal(u32, 0);

/// Initialize a CPU. Must be called on all CPUs.
pub fn init_cpu(cpu_id: u32) void {
    const elems = r.percpu_init_set.elems();

    id.local().* = cpu_id;

    for (elems) |func| {
        func();
    }
}

pub fn current() u32 {
    return id.local().*;
}

/// Wraps around CPU-local data.
pub fn CpuLocal(comptime T: type, comptime init: T) type {
    return struct {
        var storage: T linksection(".data.percpu") = init;

        /// Return a pointer to local CPU data.
        pub fn local() *T {
            return ki.impl.percpu_ptr(&storage);
        }

        /// Return a pointer to remote CPU data.
        pub fn remote(cpu: u32) *T {
            return ki.impl.percpu_ptr_other(&storage, cpu);
        }
    };
}

/// Wraps around CPU-local data with a designated symbol name.
pub fn ExportedCpuLocal(comptime T: type, comptime init: T, comptime name: []const u8) type {
    const S = struct {
        var storage: T linksection(".data.percpu") = init;

        pub fn local() @TypeOf(ki.impl.percpu_ptr(&storage)) {
            return ki.impl.percpu_ptr(&storage);
        }
        pub fn remote(cpu: u32) *T {
            return ki.impl.percpu_ptr_other(&storage, cpu);
        }
    };
    @export(&S.storage, .{ .name = name, .linkage = .strong });
    return S;
}

/// Bitmask of CPUs.
pub const CpuMask = rtl.BitMap(config.ncpus);
pub const AtomicCpuMask = rtl.AtomicBitMap(config.ncpus);
