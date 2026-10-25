const std = @import("std");

/// Read an extern or packed struct's fields with a given endianness from a byte
/// slice.
pub fn read_struct(
    comptime T: type,
    bytes: []const u8,
    comptime endian: std.lang.Endian,
) T {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct" or
            (info.@"struct".layout != .@"extern" and
                info.@"struct".layout != .@"packed"))
        {
            @compileError("Type must be an 'extern' or 'packed' struct.");
        }
    }

    var result: T = undefined;
    const str = @typeInfo(T).@"struct";

    inline for (str.field_names, str.field_types) |name, ftype| {
        const offset = @offsetOf(T, name);
        const size = @sizeOf(ftype);
        const field_bytes = bytes[offset .. offset + size];

        @field(result, name) = std.mem.readInt(ftype, field_bytes, endian);
    }

    return result;
}

/// Racily read a pointer on purpose.
pub fn racy_read(comptime T: type, ptr: *T) T {
    return @atomicLoad(T, ptr, .unordered);
}
