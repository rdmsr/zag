const b = @import("base");

pub const std_options = b.std_options;
pub const panic = b.panic;

const c = @cImport({
    @cInclude("SDL.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
});

const std = @import("std");
const ke = b.ke;
const pl = b.pl;

const default_mem_size = b.gib(1);

fn parse_mem_size(str: []const u8) !usize {
    if (str.len == 0) return default_mem_size;

    const last = str[str.len - 1];

    const mul: usize = switch (std.ascii.toLower(last)) {
        'k' => b.kib(1),
        'm' => b.mib(1),
        'g' => b.gib(1),
        else => 1,
    };

    const digits = if (mul == 1) str else str[0 .. str.len - 1];
    const size = try std.fmt.parseInt(usize, digits, 10);
    return size * mul;
}

var gui_started = std.atomic.Value(bool).init(false);

fn gui_thread() void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        std.debug.panic("Failed to initialize SDL: {s}\n", .{c.SDL_GetError()});
    }

    const window = c.SDL_CreateWindow(
        "Zag (UM)",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        800,
        600,
        c.SDL_WINDOW_SHOWN,
    );

    if (window == null) {
        std.debug.panic("Failed to create window: {s}\n", .{c.SDL_GetError()});
    }

    const renderer = c.SDL_CreateRenderer(window.?, -1, c.SDL_RENDERER_ACCELERATED);
    if (renderer == null) {
        std.debug.panic("Failed to create renderer: {s}\n", .{c.SDL_GetError()});
    }

    const fb_surface: ?*c.SDL_Surface = c.SDL_CreateRGBSurface(0, 800, 600, 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0);
    if (fb_surface == null) {
        std.debug.panic("Failed to create surface: {s}\n", .{c
            .SDL_GetError()});
    }

    const surface = fb_surface.?;

    const texture = c.SDL_CreateTexture(
        renderer.?,
        c.SDL_PIXELFORMAT_RGB888,
        c.SDL_TEXTUREACCESS_STREAMING,
        800,
        600,
    );

    pl.impl.global_state.boot_info.framebuffer = .{
        .address = @intFromPtr(surface.pixels),
        .width = 800,
        .height = 600,
        .pitch = @intCast(surface.pitch),
        .bpp = 32,
    };

    gui_started.store(true, .release);

    // Mask all signals.
    var sigset: c.sigset_t = undefined;
    _ = c.sigfillset(&sigset);
    _ = c.pthread_sigmask(c.SIG_BLOCK, &sigset, null);

    var event: c.SDL_Event = undefined;
    var quit = false;

    while (!quit) {
        const frame_start = c.SDL_GetTicks();

        while (c.SDL_PollEvent(&event) != 0) {
            if (event.type == c.SDL_QUIT) {
                quit = true;
            }
        }

        // Copy the framebuffer (surface) to a texture and render it.
        _ = c.SDL_UpdateTexture(texture, null, surface.pixels, surface.pitch);
        _ = c.SDL_RenderClear(renderer.?);
        _ = c.SDL_RenderCopy(renderer.?, texture, null, null);
        _ = c.SDL_RenderPresent(renderer.?);

        const frame_time = c.SDL_GetTicks() - frame_start;

        if (frame_time < 16) {
            c.SDL_Delay(16 - frame_time);
        }
    }

    _ = c.SDL_DestroyTexture(texture);

    // Exit.
    c.SDL_Quit();
    std.process.exit(0);
}

fn start_gui() void {
    _ = std.Thread.spawn(.{ .allocator = std.heap.page_allocator }, gui_thread, .{}) catch unreachable;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    const exe = args.next().?;

    var mem_size: usize = default_mem_size;
    var cmdline: ?[]const u8 = null;
    var ncpus: usize = 1;
    var gui = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mem-size")) {
            const val = args.next() orelse fatal("--mem-size requires a value", .{});
            mem_size = parse_mem_size(val) catch fatal("invalid mem-size", .{});
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cmdline")) {
            cmdline = args.next() orelse fatal("--cmdline requires a value", .{});
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--threads")) {
            const val = args.next() orelse fatal("--threads requires a value", .{});
            ncpus = std.fmt.parseInt(usize, val, 10) catch fatal("invalid thread count", .{});
        } else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--gui")) {
            gui = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stderr = std.Io.File.stderr().writerStreaming(init.io, &.{});
            var w = &stderr.interface;

            try w.print(
                \\Usage: {s} [options]
                \\  -m, --mem-size SIZE    Set the memory size
                \\  -c, --cmdline STR      Set the kernel cmdline
                \\  -t, --threads COUNT    Set the number of threads
                \\  -g, --gui,             Enable graphics mode using SDL2
                \\
            , .{exe});
            std.process.exit(0);
        } else {
            fatal("unknown argument: {s}", .{arg});
        }
    }

    pl.impl.global_state.params =
        .{ .ncpus = ncpus, .cmdline = cmdline, .mem_size = mem_size };

    pl.impl.global_state.boot_info.kernel_address.physical_base = 0;
    pl.impl.global_state.boot_info.kernel_address.virtual_base = 0;

    pl.impl.global_state.boot_info.rsdp = 0;
    pl.impl.global_state.boot_info.cmdline = cmdline;

    if (gui) {
        start_gui();
        while (gui_started.load(.monotonic) != true) {
            std.atomic.spinLoopHint();
        }
    }

    ke.ncpus = ncpus;

    ke.private.init(&pl.impl.global_state.boot_info);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
