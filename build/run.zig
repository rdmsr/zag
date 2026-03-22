const std = @import("std");
const config = @import("config.zig");
const image = @import("image.zig");

const QemuArgs = struct {
    suffix: []u8,
    args: [][]u8,
};

pub fn addRun(b: *std.Build, kernel: *std.Build.Step.Compile, plat: config.Platform) void {
    const run_step = b.step("run", "Run the kernel");
    const uefi = b.option(bool, "uefi", "Boot with UEFI firmware") orelse false;
    const debug = b.option(bool, "debug", "Boot in debug mode") orelse false;
    const extra_qemu_args = b.option([]const []const u8, "qemu-args", "Extra arguments to pass to QEMU") orelse &.{};

    if (plat.os == .freestanding) {
        const limine = b.dependency("limine", .{});
        const ovmf = b.dependency("ovmf", .{});
        const iso_out = image.addIso(b, plat.arch, "myos", kernel, limine);

        const qemu_bin = switch (plat.arch) {
            .x86_64 => "qemu-system-x86_64",
            .aarch64 => "qemu-system-aarch64",
            .riscv64 => "qemu-system-riscv64",
            else => "qemu-system-x86_64",
        };
        const ovmf_fd = switch (plat.arch) {
            .x86_64 => "ovmf-code-x86_64.fd",
            .aarch64 => "ovmf-code-aarch64.fd",
            .riscv64 => "ovmf-code-riscv64.fd",
            else => "ovmf-code-x86_64.fd",
        };

        const qemu = b.addSystemCommand(&.{qemu_bin});

        if (plat.arch != .x86_64 or uefi) {
            qemu.addArg("-drive");
            qemu.addPrefixedFileArg("if=pflash,format=raw,readonly=on,file=", ovmf.path(ovmf_fd));
        }

        qemu.addArgs(extra_qemu_args);
        qemu.addArg("-cdrom");
        qemu.addFileArg(iso_out.path);

        if (debug) {
            qemu.addArgs(&.{
                "-serial",    "stdio",
                "-d",         "int",
                "-D",         "qemu.log",
                "-no-reboot", "-no-shutdown",
            });
        }

        switch (plat.arch) {
            .x86_64 => {
                qemu.addArgs(&.{ "-debugcon", "stdio" });

                if (!debug) qemu.addArgs(&.{ "-enable-kvm", "-cpu", "host" });
            },
            .aarch64 => qemu.addArgs(&.{ "-machine", "virt", "-cpu", "cortex-a57" }),
            .riscv64 => qemu.addArgs(&.{ "-machine", "virt" }),
            else => {},
        }

        run_step.dependOn(&qemu.step);
    } else {
        run_step.dependOn(&b.addRunArtifact(kernel).step);
    }
}
