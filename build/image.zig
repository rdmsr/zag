const std = @import("std");

const Arch = std.Target.Cpu.Arch;

fn addLimineTool(b: *std.Build, limine: *std.Build.Dependency) *std.Build.Step.Compile {
    const tool = b.addExecutable(.{ .name = "limine", .root_module = b.addModule("limine", .{
        .target = b.graph.host,
        .link_libc = true,
    }) });
    tool.root_module.addCSourceFile(.{ .file = limine.path("limine.c") });
    return tool;
}

pub const IsoResult = struct {
    step: *std.Build.Step,
    path: std.Build.LazyPath,
};

pub fn addIso(
    b: *std.Build,
    arch: Arch,
    image_name: []const u8,
    kernel: *std.Build.Step.Compile,
    limine: *std.Build.Dependency,
) IsoResult {
    const limine_tool = addLimineTool(b, limine);
    const kernel_bin = kernel.getEmittedBin();

    const prep_script =
        \\set -euo pipefail
        \\kernel="$1"
        \\iso_root="$2"
        \\limine_conf="$3"
        \\limine_dir="$4"
        \\arch="$5"
        \\rm -rf "$iso_root"
        \\mkdir -p "$iso_root/boot/limine" "$iso_root/EFI/BOOT"
        \\cp "$kernel" "$iso_root/boot/kernel"
        \\cp "$limine_conf" "$iso_root/boot/limine/limine.conf"
        \\case "$arch" in
        \\  x86_64)
        \\    cp "$limine_dir/limine-bios.sys" "$limine_dir/limine-bios-cd.bin" "$limine_dir/limine-uefi-cd.bin" "$iso_root/boot/limine/"
        \\    cp "$limine_dir/BOOTX64.EFI" "$limine_dir/BOOTIA32.EFI" "$iso_root/EFI/BOOT/"
        \\    ;;
        \\  aarch64)
        \\    cp "$limine_dir/limine-uefi-cd.bin" "$iso_root/boot/limine/"
        \\    cp "$limine_dir/BOOTAA64.EFI" "$iso_root/EFI/BOOT/"
        \\    ;;
        \\  riscv64)
        \\    cp "$limine_dir/limine-uefi-cd.bin" "$iso_root/boot/limine/"
        \\    cp "$limine_dir/BOOTRISCV64.EFI" "$iso_root/EFI/BOOT/"
        \\    ;;
        \\  loongarch64)
        \\    cp "$limine_dir/limine-uefi-cd.bin" "$iso_root/boot/limine/"
        \\    cp "$limine_dir/BOOTLOONGARCH64.EFI" "$iso_root/EFI/BOOT/"
        \\    ;;
        \\esac
    ;

    const iso_root = b.addTempFiles();

    const prep = b.addSystemCommand(&.{ "bash", "-ceu", prep_script, "--" });

    prep.addFileArg(kernel_bin);
    prep.addDirectoryArg(iso_root.getDirectory());
    prep.addFileArg(b.path("build/limine.conf"));
    prep.addDirectoryArg(limine.path("."));
    prep.addArg(@tagName(arch));
    prep.step.dependOn(&iso_root.step);

    const mkiso = b.addSystemCommand(&.{ "xorriso", "-as", "mkisofs", "-R", "-r", "-J" });
    switch (arch) {
        .x86_64 => mkiso.addArgs(&.{
            "-b",                             "boot/limine/limine-bios-cd.bin",
            "-no-emul-boot",                  "-boot-load-size",
            "4",                              "-boot-info-table",
            "-hfsplus",                       "-apm-block-size",
            "2048",                           "--efi-boot",
            "boot/limine/limine-uefi-cd.bin", "-efi-boot-part",
            "--efi-boot-image",               "--protective-msdos-label",
        }),
        else => mkiso.addArgs(&.{
            "-hfsplus",
            "-apm-block-size",
            "2048",
            "--efi-boot",
            "boot/limine/limine-uefi-cd.bin",
            "-efi-boot-part",
            "--efi-boot-image",
            "--protective-msdos-label",
        }),
    }
    mkiso.addDirectoryArg(iso_root.getDirectory());
    mkiso.addArg("-o");
    const iso_out = mkiso.addOutputFileArg(b.fmt("{s}.iso", .{image_name}));
    mkiso.step.dependOn(&prep.step);

    if (arch == .x86_64) {
        const bios_install = b.addRunArtifact(limine_tool);
        bios_install.addArg("bios-install");
        bios_install.addFileArg(iso_out);
        bios_install.step.dependOn(&mkiso.step);
    }

    const install_iso = b.addInstallFile(iso_out, b.fmt("{s}.iso", .{image_name}));
    install_iso.step.dependOn(&mkiso.step);
    return .{
        .step = &install_iso.step,
        .path = iso_out,
    };
}
