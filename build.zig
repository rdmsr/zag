const std = @import("std");
const builtin = @import("builtin");
const config = @import("build/config.zig");
const image = @import("build/image.zig");
const run = @import("build/run.zig");

pub fn build(b: *std.Build) void {
    const config_step = b.step("config", "Show the config menu");
    config_step.dependOn(config.configStep(b));

    // Parse the config
    const cfg = config.parseConfig(b) catch |err| {
        if (err == error.FileNotFound) {
            b.default_step.dependOn(
                &b.addFail("No .config found, run `zig build config` first").step,
            );
        } else {
            b.default_step.dependOn(
                &b.addFail("Failed to parse .config").step,
            );
        }
        return;
    };

    // Generate the zig config file we can import in the code
    const config_wf = config.generateConfig(b, cfg) catch {
        b.default_step.dependOn(
            &b.addFail("Failed to generate config.gen.zig").step,
        );
        return;
    };

    // Get the target platform (might be linux or freestanding)
    const plat = config.getPlatform(cfg) catch {
        b.default_step.dependOn(
            &b.addFail("Invalid platform (this should not happen!)").step,
        );
        return;
    };

    const optimize = b.standardOptimizeOption(.{});

    const config_module = b.createModule(.{
        .root_source_file = config_wf.getDirectory().path(b, "config.gen.zig"),
        .optimize = optimize,
    });

    // first pass
    const empty_cmd = b.addSystemCommand(&.{ "python3", "build/ksyms.py", "--empty" });
    empty_cmd.addArg("--output");
    const empty_zig = empty_cmd.addOutputFileArg("ksyms_empty.gen.zig");
    const empty_ksyms_module = b.createModule(.{
        .root_source_file = empty_zig,
        .optimize = optimize,
    });

    const rtl_module = b.createModule(.{
        .root_source_file = b.path("src/rtl/root.zig"),
        .optimize = optimize,
    });

    rtl_module.addImport("rtl", rtl_module);

    const base_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "config", .module = config_module },
            .{ .name = "rtl", .module = rtl_module },
        },
        .optimize = optimize,
    });

    base_module.addImport("base", base_module);

    const kernel_nosym = addKernel(b, plat, optimize, config_module, empty_ksyms_module, rtl_module, base_module);

    b.step("kernel-nosym", "Build nosym kernel").dependOn(&kernel_nosym.step);

    // generate symbols
    const ksyms = b.addSystemCommand(&.{ "python3", "build/ksyms.py" });
    ksyms.addArg("--input");
    ksyms.step.dependOn(&kernel_nosym.step);
    ksyms.addFileArg(kernel_nosym.getEmittedBin());
    ksyms.addArg("--output");
    const ksyms_zig = ksyms.addOutputFileArg("ksyms.gen.zig");
    const ksyms_module = b.createModule(.{
        .root_source_file = ksyms_zig,
        .optimize = optimize,
    });

    // second pass
    const kernel = addKernel(b, plat, optimize, config_module, ksyms_module, rtl_module, base_module);

    b.default_step.dependOn(&b.addInstallArtifact(kernel, .{}).step);

    const docs_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .imports = &.{
            .{ .name = "config", .module = config_module },
            .{ .name = "ksyms", .module = ksyms_module },
            .{ .name = "rtl", .module = rtl_module },
        },
    });
    docs_module.addImport("base", docs_module);

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
    const result = image.addIso(b, plat.arch, "myos", kernel, b.dependency("limine", .{}));
    iso_step.dependOn(result.step);

    run.addRun(b, kernel, plat);

    const rtl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rtl/root.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(rtl_tests);
    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_tests.step);
}

fn targetQueryForPlatform(plat: config.Platform) std.Target.Query {
    var q: std.Target.Query = .{
        .cpu_arch = plat.arch,
        .os_tag = plat.os,
        .abi = if (plat.os == .freestanding) .none else .gnu,
        .cpu_model = .baseline,
    };

    if (plat.os == .freestanding) {
        switch (plat.arch) {
            .x86_64 => {
                const f = std.Target.Cpu.Feature.FeatureSetFns(std.Target.x86.Feature);
                q.cpu_features_add = f.featureSet(&.{.soft_float});
                q.cpu_features_sub = f.featureSet(&.{ .x87, .mmx, .sse, .sse2 });
            },
            .aarch64 => {
                const f = std.Target.Cpu.Feature.FeatureSetFns(std.Target.aarch64.Feature);
                q.cpu_features_sub = f.featureSet(&.{ .fp_armv8, .neon });
            },
            .riscv64 => {},
            else => {},
        }
    }

    return q;
}

fn addKernel(b: *std.Build, plat: config.Platform, optimize: std.builtin.OptimizeMode, config_module: *std.Build.Module, ksyms_module: *std.Build.Module, rtl: *std.Build.Module, base: *std.Build.Module) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(targetQueryForPlatform(plat));

    const name = b.fmt("kernel-{s}", .{@tagName(plat.arch)});

    const platform_name = if (plat.bootloader) |bl|
        switch (bl) {
            .Limine => "limine",
        }
    else
        @tagName(plat.arch);

    const root_source_file = b.fmt("src/platform/{s}/entry.zig", .{platform_name});

    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
        }),
    });

    kernel.root_module.addImport("config", config_module);
    kernel.root_module.addImport("ksyms", ksyms_module);
    kernel.root_module.addImport("base", base);
    kernel.root_module.addImport("rtl", rtl);

    kernel.use_llvm = true;
    kernel.use_lld = true;

    if (plat.os == .freestanding) {
        kernel.linkage = .static;
        kernel.pie = false;

        kernel.root_module.pic = false;
        kernel.root_module.strip = false;
        kernel.root_module.stack_check = false;
        kernel.root_module.stack_protector = false;
        kernel.root_module.unwind_tables = .none;

        kernel.entry = .{ .symbol_name = "kmain" };

        kernel.root_module.code_model = switch (plat.arch) {
            .x86_64 => .kernel,
            .riscv64 => .medium,
            else => .large,
        };

        switch (plat.arch) {
            .x86_64 => kernel.root_module.red_zone = false,
            else => {},
        }

        kernel.linker_script = b.path(b.fmt("build/linker-scripts/{s}.lds", .{@tagName(plat.arch)}));
    } else {
        kernel.linker_script = b.path("build/linker-scripts/uml.lds");
        kernel.root_module.link_libc = true;
        kernel.linker_allow_shlib_undefined = true;
        kernel.root_module.linkSystemLibrary("sdl2-compat", .{ .use_pkg_config = .force });
        kernel.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib64" });
    }

    return kernel;
}
