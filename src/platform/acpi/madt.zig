const std = @import("std");
const b = @import("base");
const acpi = b.pl.acpi;

pub var madt_ptr: ?*acpi.Madt = null;

pub const MadtIterator = struct {
    madt: *const acpi.Madt,
    i: usize,

    pub fn next(self: *MadtIterator) ?*const acpi.MadtEntryHeader {
        const entries_size = self.madt.header.length - @sizeOf(acpi.Madt);
        if (self.i >= entries_size) return null;
        const entry: *const acpi.MadtEntryHeader = @ptrFromInt(@intFromPtr(&self.madt.entries) + self.i);
        self.i += @max(2, entry.length);
        return entry;
    }
};

pub fn iterator() MadtIterator {
    return .{
        .madt = madt_ptr orelse @panic("MADT not initialized"),
        .i = 0,
    };
}
