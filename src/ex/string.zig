//! Generic string interning facility.
//! Used everywhere where strings might repeat, such as the namecache or thread
//! names.

const r = @import("root");
const std = @import("std");

const ke = r.ke;
const rcu = r.rcu;
const mm = r.mm;

const Entry = struct {
    string: []const u8,
    ref: std.atomic.Value(u32),
    link: rcu.SList.Entry,
};

const Context = struct {
    pub const Key = []const u8;

    pub fn hash(key: Key, seed: usize) u32 {
        const hash64 = std.hash.Wyhash.hash(seed, key);
        return @truncate(hash64);
    }

    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn key_of(obj: *Entry) Key {
        return obj.string;
    }

    pub fn is_alive(obj: *Entry) bool {
        return obj.ref.load(.monotonic) > 0;
    }
};

/// Represents an interned string.
/// The word is used to either point to an `Entry` or as inline storage,
/// depending on the length (and depending on the platform).
/// Inline Layout:
/// |tag (bit 0)|len (bits 1-7)|string
pub const InternedString = packed struct(usize) {
    bits: usize,

    const Self = @This();

    fn from_ptr(e: *Entry) Self {
        return .{ .bits = @intFromPtr(e) };
    }

    fn as_entry(self: *const Self) ?*Entry {
        if (self.bits & 1 != 0) return null;
        return @ptrFromInt(self.bits);
    }

    fn from_inline(s: []const u8) Self {
        var buf: [@sizeOf(usize)]u8 = @splat(0);

        // byte 0: tag (bit 0) | len (bits 1-7)
        buf[0] = 1 | (@as(u8, @truncate(s.len)) << 1);
        @memcpy(buf[1..][0..s.len], s);

        return .{ .bits = @bitCast(buf) };
    }

    fn should_inline(len: usize) bool {
        // Only inline strings on 64-bit; it's not worth it on 32-bit systems,
        // we would only get 3 bytes!
        return @sizeOf(usize) > 4 and len <= 7;
    }

    pub fn slice(self: *const Self) []const u8 {
        if (self.bits & 1 != 0) {
            const buf: *const [@sizeOf(usize)]u8 = @ptrCast(&self.bits);
            const len: usize = buf[0] >> 1;
            return buf[1..][0..len];
        }

        const entry: *Entry = @ptrFromInt(self.bits);
        return entry.string;
    }
};

const Table = rcu.HashTable(Entry, "link", Context);
const EntryZone = mm.zone.TypedZone(Entry);

var domain: *ke.smr.Domain = undefined;
var table: Table = undefined;
var entry_zone: EntryZone = undefined;

/// Initialize the string interning facility.
pub fn init() void {
    domain = mm.zone.smr_sys_domain;

    table.init(.{
        .smr = domain,
        .policy = .Balanced,
    }) catch unreachable;

    entry_zone.init("str entry", .{
        .smr = domain,
        .smr_reclaim = reclaim,
    });
}

pub fn retain(string: []const u8) InternedString {
    if (InternedString.should_inline(string.len)) {
        return .from_inline(string);
    }

    {
        // Fast path where the string already exists.
        const ipl = ke.smr.enter(domain);
        defer ke.smr.exit(domain, ipl);
        if (table.get(string)) |e| {
            _ = e.ref.fetchAdd(1, .monotonic);
            return .from_ptr(e);
        }
    }

    // The string (probably) doesn't exist, create a new one.
    var new_entry: *Entry = entry_zone.create() catch unreachable;

    new_entry.string = mm.zone.gpa.dupe(u8, string) catch unreachable;
    new_entry.ref = .init(1);

    const ipl = ke.smr.enter(domain);
    const entry = table.get_or_insert(string, &new_entry.link);

    // We are pretty sure that the string doesn't exist already,
    // but another thread might race us and end up doing the same work
    // we're trying to do, in that case we discard everything we've done.
    if (entry) |e| {
        _ = e.ref.fetchAdd(1, .monotonic);

        ke.smr.exit(domain, ipl);
        entry_zone.destroy(new_entry);
        return .from_ptr(e);
    }

    ke.smr.exit(domain, ipl);

    return .from_ptr(new_entry);
}

pub fn release(string: InternedString) void {
    const e = string.as_entry() orelse return;
    const old = e.ref.fetchSub(1, .monotonic);

    if (old == 1) {
        // The window where the string has refcnt=0 and the entry has not
        // yet been removed is handled by the table's is_alive check on
        // insertion, ensuring that strings with refcnt=0 get destroyed
        // and replaced by the new one.
        const ipl = ke.smr.enter(domain);
        table.remove(&e.link);
        ke.smr.exit(domain, ipl);

        entry_zone.destroy(e);
        return;
    }
}

fn reclaim(entry: *Entry) void {
    mm.zone.gpa.free(entry.string);
}
