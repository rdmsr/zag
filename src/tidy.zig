//! Whines about bad code style.
//! Inspired by TigerBeetle's similar tool.
//! (https://github.com/tigerbeetle/tigerbeetle/blob/main/src/tidy.zig)

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// We aren't in the 80s anymore, but 80 columns is optimal for comment
/// readability (and also sunk cost fallacy).
const max_cols = 80;

/// Afford this being a bit bigger than 70 because we only have 80 cols to work
/// with.
const max_function_length = 90;

/// Error on files and functions not being documented.
const error_func_not_documented = false;
const error_file_not_documented = true;

test "tidy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var errors: Errors = .{};

    const outbuf = try gpa.alloc(u8, 1024 * 8);
    defer gpa.free(outbuf);

    const out = try run_command(
        io,
        &.{ "git", "ls-files", "-z" },
        outbuf,
    );

    var path_iterator = std.mem.splitScalar(
        u8,
        out[0 .. out.len - 1],
        0,
    );

    const filebuf = try gpa.alloc(u8, 1 * 1024 * 1024);
    defer gpa.free(filebuf);

    while (path_iterator.next()) |path| {
        const file = try SourceFile.read(
            io,
            path,
            filebuf,
        );

        try tidy_file(gpa, file, &errors);
    }

    if (errors.count > 0) {
        return error.Untidy;
    }
}

const Errors = struct {
    count: u32 = 0,

    pub fn add_long_line(
        errors: *Errors,
        file: SourceFile,
        line_num: usize,
    ) void {
        errors.emit(
            "{s}:{d}: error: line exceeds {} columns\n",
            .{ file.path, line_num, max_cols },
        );
    }

    pub fn add_file_not_documented(
        errors: *Errors,
        file: SourceFile,
    ) void {
        errors.emit(
            "{s}: error: file not documented\n",
            .{file.path},
        );
    }

    pub fn add_wrong_fn_type_name(
        errors: *Errors,
        name: []const u8,
        file: SourceFile,
        line_num: usize,
    ) void {
        errors.emit(
            "{s}:{d}: error: type name '{s}' should be PascalCase\n",
            .{ file.path, line_num, name },
        );
    }

    pub fn add_wrong_fn_name(
        errors: *Errors,
        name: []const u8,
        file: SourceFile,
        line_num: usize,
    ) void {
        errors.emit(
            "{s}:{d}: error: function name '{s}' should be snake_case\n",
            .{ file.path, line_num, name },
        );
    }

    pub fn add_defer_without_newline(
        errors: *Errors,
        file: SourceFile,
        line_num: usize,
        keyword: []const u8,
    ) void {
        errors.emit(
            "{s}:{d}: error: {s} must be followed by a blank line\n",
            .{ file.path, line_num, keyword },
        );
    }

    pub fn add_function_too_long(
        errors: *Errors,
        name: []const u8,
        file: SourceFile,
        line_num: usize,
    ) void {
        errors.emit(
            "{s}:{d}: error: function '{s}' exceeds {} lines\n",
            .{ file.path, line_num, name, max_function_length },
        );
    }

    pub fn add_function_not_documented(
        errors: *Errors,
        name: []const u8,
        file: SourceFile,
        line_num: usize,
    ) void {
        errors.emit(
            "{s}:{d}: error: function '{s}' not documented\n",
            .{ file.path, line_num, name },
        );
    }

    pub fn add_function_unused(
        errors: *Errors,
        name: []const u8,
        file: SourceFile,
        line_num: usize,
    ) void {
        errors.emit(
            "{s}:{d}: error: private function '{s}' appears unused\n",
            .{ file.path, line_num, name },
        );
    }

    pub fn add_banned(
        errors: *Errors,
        file: SourceFile,
        line_num: usize,
        func: []const u8,
        replacement: []const u8,
    ) void {
        errors.emit(
            "{s}:{d}: error: {s} is banned, use {s}\n",
            .{ file.path, line_num, func, replacement },
        );
    }

    fn emit(errors: *Errors, comptime fmt: []const u8, args: anytype) void {
        comptime assert(fmt[fmt.len - 1] == '\n');
        errors.count += 1;

        std.debug.print(fmt, args);
    }
};

const SourceFile = struct {
    path: []const u8,
    text: [:0]const u8,

    pub fn read(
        io: std.Io,
        path: []const u8,
        buffer: []u8,
    ) !SourceFile {
        var dir = std.Io.Dir.cwd();
        var file = try dir.openFile(io, path, .{});
        defer file.close(io);

        // Try and buffer reads a bit.
        var buf: [4096]u8 = undefined;

        var reader = file.reader(io, &buf);
        const bytes_read = try reader.interface.readSliceShort(buffer);

        buffer[bytes_read] = 0;

        return .{
            .path = path,
            .text = buffer[0..bytes_read :0],
        };
    }

    fn has_extension(file: SourceFile, extension: []const u8) bool {
        assert(extension.len > 0);
        assert(extension[0] == '.');
        return std.mem.endsWith(u8, file.path, extension);
    }

    fn line_number(file: SourceFile, offset: usize) usize {
        assert(offset <= file.text.len);
        return std.mem.count(u8, file.text[0..offset], "\n") + 1;
    }
};

fn tidy_file(gpa: Allocator, file: SourceFile, errors: *Errors) !void {
    if (!file.has_extension(".zig")) return;
    if (std.mem.eql(u8, file.path, "build.zig")) return;
    if (std.mem.eql(u8, file.path, "build/config.zig")) return;
    if (std.mem.eql(u8, file.path, "build/image.zig")) return;
    if (std.mem.eql(u8, file.path, "build/run.zig")) return;
    if (std.mem.eql(u8, file.path, "build/ksyms.zig")) return;
    if (std.mem.eql(u8, file.path, "src/tidy.zig")) return;

    // Tidy lines.
    var line_iterator = std.mem.splitScalar(u8, file.text, '\n');
    var line_index: u32 = 0;

    while (line_iterator.next()) |line| : (line_index += 1) {
        tidy_line(file, line, line_index + 1, errors);
    }

    // Tidy banned things.
    tidy_banned(file, errors);

    // Tidy the AST.
    var tree = try std.zig.Ast.parse(gpa, file.text, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const has_file_doc = tree.tokenTag(0) == .container_doc_comment;

    if (!has_file_doc and error_file_not_documented) {
        errors.add_file_not_documented(file);
    }

    tidy_ast(file, tree, errors);
}

fn tidy_line(
    file: SourceFile,
    line: []const u8,
    line_num: usize,
    errors: *Errors,
) void {
    if (line.len > max_cols) {
        errors.add_long_line(file, line_num);
    }
}

fn tidy_ast(file: SourceFile, tree: std.zig.Ast, errors: *Errors) void {
    tidy_defer(file, tree, errors);

    for (tree.rootDecls()) |decl| {
        if (tree.nodeTag(decl) != .fn_decl) continue;
        tidy_function(file, tree, decl, errors);
    }
}

fn tidy_function(
    file: SourceFile,
    tree: std.zig.Ast,
    decl: std.zig.Ast.Node.Index,
    errors: *Errors,
) void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, decl).?;
    const name = tree.tokenSlice(proto.name_token.?);

    const lineno = tree.tokenLocation(
        0,
        proto.name_token.?,
    ).line;

    const start_line = tree.tokenLocation(0, tree.firstToken(decl)).line + 1;
    const end_line = tree.tokenLocation(0, tree.lastToken(decl)).line + 1;
    const line_count = end_line - start_line + 1;

    const return_node = proto.ast.return_type.unwrap().?;
    const return_token = tree.firstToken(return_node);
    const returns_type = tree.nodeTag(return_node) == .identifier and
        std.mem.eql(u8, tree.tokenSlice(return_token), "type");

    const first = tree.firstToken(decl);
    const documented = first > 0 and
        tree.tokenTag(first - 1) == .doc_comment;

    if (!documented and error_func_not_documented) {
        errors.add_function_not_documented(name, file, lineno + 1);
    }

    if (returns_type and std.ascii.isLower(name[0])) {
        errors.add_wrong_fn_type_name(name, file, lineno + 1);
    }

    if (!returns_type) {
        blk: for (name) |c| {
            if (std.ascii.isUpper(c)) {
                errors.add_wrong_fn_name(name, file, lineno + 1);
                break :blk;
            }
        }
    }

    if (!returns_type and line_count > max_function_length) {
        // Functions that return types are allowed to be more lines,
        // since they are basically struct/type definitions.
        errors.add_function_too_long(name, file, lineno + 1);
    }

    if (!function_is_externally_visible(tree, first, proto.ast.fn_token) and
        !function_has_reference(tree, proto.name_token.?))
    {
        errors.add_function_unused(name, file, lineno + 1);
    }
}

fn function_is_externally_visible(
    tree: std.zig.Ast,
    first: std.zig.Ast.TokenIndex,
    fn_token: std.zig.Ast.TokenIndex,
) bool {
    for (first..fn_token) |index| {
        const token: std.zig.Ast.TokenIndex = @intCast(index);
        switch (tree.tokenTag(token)) {
            .keyword_pub, .keyword_export, .keyword_extern => return true,
            else => {},
        }
    }
    return false;
}

fn function_has_reference(
    tree: std.zig.Ast,
    name_token: std.zig.Ast.TokenIndex,
) bool {
    const name = tree.tokenSlice(name_token);
    for (0..tree.tokens.len) |index| {
        const token: std.zig.Ast.TokenIndex = @intCast(index);
        if (token == name_token or tree.tokenTag(token) != .identifier) continue;
        if (std.mem.eql(u8, tree.tokenSlice(token), name)) return true;
    }
    return false;
}

fn tidy_banned(file: SourceFile, errors: *Errors) void {
    const ban_list: []const struct { []const u8, []const u8 } = &.{
        .{ "debug.assert(", "unqualified assert" },
        .{ "Self = @This()", "proper type name" },
        .{ "catch unreachable", "proper error handling or documentation" },
        .{ "catch {}", "proper error handling or documentation" },
        .{ "= .init(", "full type name" },
        .{ ".?", "orelse unreachable" },
    };

    for (ban_list) |ban_item| {
        const banned, const replacement = ban_item;
        if (std.mem.indexOf(u8, file.text, banned)) |offset| {
            const lineno = file.line_number(offset);
            errors.add_banned(file, lineno, banned, replacement);
        }
    }
}

fn tidy_defer(file: SourceFile, tree: std.zig.Ast, errors: *Errors) void {
    for (0..tree.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        if (tree.nodeTag(node) != .@"defer" and
            tree.nodeTag(node) != .@"errdefer") continue;

        const last_token = tree.lastToken(node);
        const end_token = if (tree.tokenTag(last_token + 1) == .semicolon)
            last_token + 1
        else
            last_token;
        const end = tree.tokenStart(end_token) + tree.tokenSlice(end_token).len;

        if (!std.mem.startsWith(u8, file.text[end..], "\n\n")) {
            const main_token = tree.nodeMainToken(node);
            const line_num = tree.tokenLocation(0, main_token).line + 1;
            errors.add_defer_without_newline(
                file,
                line_num,
                tree.tokenSlice(main_token),
            );
        }
    }
}

fn run_command(io: std.Io, command: []const []const u8, outbuf: []u8) ![]u8 {
    var proc = try std.process.spawn(
        io,
        .{ .argv = command, .stdout = .pipe },
    );

    defer _ = proc.wait(io) catch {};

    var buf: [128]u8 = undefined;
    var freader = proc.stdout.?.reader(io, &buf);
    const reader = &freader.interface;

    const bytes_read = try reader.readSliceShort(outbuf);

    return outbuf[0..bytes_read];
}
