//! fw_cfg support routines.

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

pub const Selector = enum(u16) {
    Signature = 0,
    Id = 1,
    FileDir = 0x19,
    _,

    pub fn from(val: u16) Selector {
        return @fromBackingInt(val);
    }

    pub fn value(self: Selector) u16 {
        return @backingInt(self);
    }
};

pub const Ops = struct {
    select_fn: *const fn (id: Selector) void,
    read_fn: *const fn (buf: []u8) void,
};

const signature = "QEMU".*;

pub const InitError = error{InvalidSignature};

pub const FwCfg = struct {
    ops: Ops,

    pub fn init(ops: Ops) error{InvalidSignature}!FwCfg {
        var ret: FwCfg = .{ .ops = ops };
        var sig_buf: [4]u8 = undefined;

        ret.select(.Signature);
        ret.read(&sig_buf);

        if (!std.mem.eql(u8, &sig_buf, &signature)) {
            return error.InvalidSignature;
        }

        return ret;
    }

    pub fn select(self: *const FwCfg, id: Selector) void {
        self.ops.select_fn(id);
    }

    pub fn read(self: *const FwCfg, buf: []u8) void {
        self.ops.read_fn(buf);
    }

    pub fn files(self: *const FwCfg) FileIterator {
        self.select(.FileDir);
        var buf: [4]u8 = undefined;
        self.read(&buf);

        return .{
            .i = 0,
            .file_cnt = std.mem.readInt(u32, buf[0..4], .big),
            .fw_cfg = self,
        };
    }
};

pub const File = extern struct {
    size: u32,
    selector: Selector,
    reserved: u16,
    name: [56]u8,

    /// Read the contents of the file in `buf`.
    /// Note that this invalidates any pending iterator.
    pub fn read(self: *const File, fw_cfg: *const FwCfg, buf: []u8) void {
        assert(buf.len <= self.size);
        fw_cfg.select(self.selector);
        fw_cfg.read(buf);
    }

    /// Name as a zig slice.
    pub fn name_str(self: *const File) []const u8 {
        return mem.sliceTo(&self.name, 0);
    }
};

pub const FileIterator = struct {
    fw_cfg: *const FwCfg,
    file_cnt: u32,
    i: u32,

    pub fn next(self: *FileIterator) ?File {
        if (self.i == self.file_cnt) return null;

        var file: File = undefined;
        self.fw_cfg.read(mem.asBytes(&file));
        file.size = mem.readInt(u32, mem.asBytes(&file.size), .big);

        file.selector = .from(mem.readInt(
            u16,
            mem.asBytes(&file.selector),
            .big,
        ));

        self.i += 1;
        return file;
    }
};
