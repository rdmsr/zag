const std = @import("std");
const builtin = @import("builtin");
const config = @import("build/config.zig");
const image = @import("build/image.zig");
const run = @import("build/run.zig");
const zonfig = @import("zonfig");

pub fn build(b: *std.Build) void {
    const zonfig_dep = b.dependency("zonfig", .{});

    zonfig.addConfigStep(b, zonfig_dep, "config.zig.zon", ".config.zig.zon");

    b.dependOnFileMetadata(b.path(".config.zig.zon"));

    // Parse the config or fail if file is not present
    const cfg = config.parseConfig(b) catch |err| {
        b.default_step.dependOn(
            &b.addFail(b.fmt("Failed to parse config, have you run `zig build config`? (Error: {any})", .{err})).step,
        );

        return;
    };

    // Get the target platform
    const plat = config.getPlatform(cfg) catch {
        b.default_step.dependOn(
            &b.addFail("Invalid platform (this should not happen!)").step,
        );
        return;
    };

    const optimize = b.standardOptimizeOption(.{});

    const config_module = zonfig.createConfigModule(b, zonfig_dep, "config.zig.zon", ".config.zig.zon");

    const rtl_module = b.createModule(.{
        .root_source_file = b.path("src/rtl/root.zig"),
        .optimize = optimize,
    });

    rtl_module.addImport("rtl", rtl_module);

    const arch = switch (plat.arch) {
        .x86_64 => "amd64",
        else => @tagName(plat.arch),
    };

    const arch_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("src/arch/{s}/root.zig", .{arch})),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = config_module },
            .{ .name = "rtl", .module = rtl_module },
        },
    });

    const boot_info_module = b.createModule(.{
        .root_source_file = b.path("src/loader/info.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "arch", .module = arch_module },
        },
    });

    const dst_module = b.createModule(.{
        .root_source_file = b.path("src/dst/root.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rtl", .module = rtl_module },
            .{ .name = "config", .module = config_module },
        },
    });

    const firmware_module = b.createModule(.{
        .root_source_file = b.path(b.fmt("src/firmware/root.zig", .{})),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rtl", .module = rtl_module },
        },
    });

    const kernel = addKernel(b, plat, optimize, config_module, rtl_module, arch_module);

    const loader = addLoader(b, plat, optimize, config_module, rtl_module, arch_module);

    kernel.root_module.addImport("boot_info", boot_info_module);
    loader.root_module.addImport("boot_info", boot_info_module);

    kernel.root_module.addImport("firmware", firmware_module);
    kernel.root_module.addImport("dst", dst_module);

    b.default_step.dependOn(&b.addInstallArtifact(loader, .{}).step);
    b.default_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    const docs_module = b.createModule(.{
        .root_source_file = b.path("src/sys/root.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "config", .module = config_module },
            .{ .name = "rtl", .module = rtl_module },
            .{ .name = "arch", .module = arch_module },
            .{ .name = "firmware", .module = firmware_module },
        },
    });

    const docs_obj = b.addObject(.{
        .name = "kernel_docs",
        .root_module = docs_module,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate and install documentation");
    docs_step.dependOn(&install_docs.step);

    const iso_step = b.step("iso", "Build the ISO image");
    const result = image.addIso(b, plat.arch, "myos", kernel, loader, b.dependency("limine", .{}));
    iso_step.dependOn(result.step);

    run.addRun(b, kernel, loader, cfg, plat);

    const rtl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rtl/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    rtl_tests.root_module.addImport("rtl", rtl_tests.root_module);

    const run_tests = b.addRunArtifact(rtl_tests);
    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_tests.step);
}

fn targetQueryForPlatform(plat: config.Platform) std.Target.Query {
    var q: std.Target.Query = .{
        .cpu_arch = plat.arch,
        .os_tag = plat.os,
        .abi = .none,
        .cpu_model = .baseline,
    };

    switch (plat.arch) {
        .x86_64 => {
            const f = std.Target.Cpu.Feature.FeatureSetFns(std.Target.x86.Feature);
            q.abi = .sf;
            q.cpu_features_sub = f.featureSet(&.{ .mmx, .sse, .sse2 });
        },
        .aarch64 => {
            const f = std.Target.Cpu.Feature.FeatureSetFns(std.Target.aarch64.Feature);
            q.cpu_features_sub = f.featureSet(&.{ .fp_armv8, .neon });
        },
        .riscv64 => {},
        else => {},
    }

    return q;
}

fn addKernel(b: *std.Build, plat: config.Platform, optimize: std.builtin.OptimizeMode, config_module: *std.Build.Module, rtl: *std.Build.Module, arch: *std.Build.Module) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(targetQueryForPlatform(plat));

    const name = b.fmt("kernel-{s}", .{@tagName(plat.arch)});

    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sys/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    kernel.root_module.addImport("arch", arch);
    kernel.root_module.addImport("config", config_module);
    kernel.root_module.addImport("rtl", rtl);

    kernel.link_gc_sections = false;

    kernel.use_llvm = true;
    kernel.use_lld = true;

    kernel.root_module.omit_frame_pointer = false;

    const modules: []const *std.Build.Module = &.{ config_module, rtl, arch, kernel.root_module };

    kernel.linkage = .static;
    kernel.pie = false;

    for (modules) |m| {
        m.pic = false;
        m.strip = false;
        m.stack_check = false;
        m.stack_protector = false;
        m.unwind_tables = .none;
        m.omit_frame_pointer = false;

        m.code_model = switch (plat.arch) {
            .x86_64 => .kernel,
            .riscv64 => .medium,
            else => .large,
        };

        switch (plat.arch) {
            .x86_64 => {
                m.red_zone = false;
            },
            else => {},
        }
    }

    kernel.entry = .{ .symbol_name = "kmain" };

    switch (plat.arch) {
        .x86_64 => {
            kernel.root_module.addAssemblyFile(b.path("src/sys/kern/amd64/locore.s"));
            kernel.root_module.addAssemblyFile(b.path("src/sys/platform/pc/ap.s"));
        },
        .riscv64 => {
            kernel.root_module.addAssemblyFile(b.path("src/sys/kern/riscv64/locore.s"));
        },
        else => {},
    }

    kernel.linker_script = b.path(b.fmt("build/linker-scripts/kernel/{s}.lds", .{@tagName(plat.arch)}));

    return kernel;
}

fn addLoader(b: *std.Build, plat: config.Platform, optimize: std.builtin.OptimizeMode, config_module: *std.Build.Module, rtl: *std.Build.Module, arch_module: *std.Build.Module) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(targetQueryForPlatform(plat));

    const name = b.fmt("loader-{s}-{s}", .{ @tagName(plat.arch), @tagName(plat.bootloader) });

    const loader = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/loader/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    loader.root_module.addImport("arch", arch_module);
    loader.root_module.addImport("config", config_module);
    loader.root_module.addImport("rtl", rtl);
    switch (plat.arch) {
        .x86_64 => loader.root_module.addAssemblyFile(b.path("src/loader/amd64/jump.s")),
        .riscv64 => loader.root_module.addAssemblyFile(b.path("src/loader/riscv64/jump.s")),
        else => {},
    }

    loader.use_llvm = true;
    loader.use_lld = true;

    loader.root_module.omit_frame_pointer = false;

    loader.entry = .{ .symbol_name = "loader_entry" };

    const modules: []const *std.Build.Module = &.{ arch_module, config_module, rtl, loader.root_module };

    loader.linkage = .static;
    loader.pie = false;

    for (modules) |m| {
        m.pic = false;
        m.strip = false;
        m.stack_check = false;
        m.stack_protector = false;
        m.unwind_tables = .none;
        m.omit_frame_pointer = false;

        m.code_model = switch (plat.arch) {
            .x86_64 => .kernel,
            .riscv64 => .medium,
            else => .large,
        };

        switch (plat.arch) {
            .x86_64 => {
                m.red_zone = false;
            },
            else => {},
        }
    }

    loader.linker_script = b.path(b.fmt("build/linker-scripts/loader/{s}.lds", .{@tagName(plat.arch)}));

    return loader;
}
