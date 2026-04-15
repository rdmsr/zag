//! Hypervisor detection and identification.
const std = @import("std");
const amd64 = @import("root.zig");
pub const kvm = @import("hv/kvm.zig");

pub const Vendor = enum(u32) {
    Unknown,
    KVM,
    TCG,
    VMWare,
};

pub const VendorData = union(Vendor) {
    Unknown: void,
    KVM: kvm.Info,
    TCG: void,
    VMWare: void,
};

pub const Info = struct {
    vendor: Vendor,
    data: VendorData,
};

pub var info: ?Info = null;

const known_vendors = [_]struct {
    string: *const [12:0]u8,
    vendor: Vendor,
}{
    .{ .string = "KVMKVMKVM\x00\x00\x00", .vendor = .KVM },
    .{ .string = "TCGTCGTCG\x00\x00\x00", .vendor = .TCG },
    .{ .string = "VMwareVMware", .vendor = .VMWare },
};

pub fn detect() void {
    const r = amd64.CpuidRequest.execute(.HypervisorId);
    var hypervisor_brand: [12]u8 = undefined;
    std.mem.writeInt(u32, hypervisor_brand[0..4], r.ebx, .little);
    std.mem.writeInt(u32, hypervisor_brand[4..8], r.ecx, .little);
    std.mem.writeInt(u32, hypervisor_brand[8..12], r.edx, .little);

    var vendor = Vendor.Unknown;

    for (known_vendors) |h| {
        if (std.mem.eql(u8, hypervisor_brand[0..], h.string[0..])) {
            vendor = h.vendor;
            break;
        }
    }

    const data: VendorData = switch (vendor) {
        .KVM => .{ .KVM = kvm.detect(r.eax) },
        .Unknown, .TCG, .VMWare => .{ .Unknown = {} },
    };

    info = Info{
        .vendor = vendor,
        .data = data,
    };
}
