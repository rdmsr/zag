/// Type-safe measurement units.
const std = @import("std");

const Dimension = enum { Time };

fn scale_value(comptime from_scale: u64, comptime to_scale: u64, value: u64) u64 {
    if (comptime from_scale >= to_scale) {
        return value * comptime (from_scale / to_scale);
    } else {
        return value / comptime (to_scale / from_scale);
    }
}

pub fn Unit(
    comptime dim: Dimension,
    comptime scale: u64,
    comptime unit_suffix: []const u8,
) type {
    return struct {
        const Self = @This();
        pub const dimension = dim;
        pub const base_per_unit = scale;

        value: u64,

        fn check(comptime T: type) void {
            comptime {
                if (!(@typeInfo(T) == .@"struct" and @hasDecl(T, "dimension")))
                    @compileError(@typeName(T) ++ " is not a unit");
                if (T.dimension != dim)
                    @compileError("cannot convert between " ++ @tagName(T.dimension) ++
                        " and " ++ @tagName(dim));
            }
        }

        pub fn init(value: u64) Self {
            return .{ .value = value };
        }

        pub fn to(self: Self, comptime T: type) T {
            check(T);
            return T.init(scale_value(scale, T.base_per_unit, self.value));
        }

        pub fn from(other: anytype) Self {
            const From = @TypeOf(other);
            check(From);
            return Self.init(scale_value(From.base_per_unit, scale, other.value));
        }

        pub inline fn format(self: Self, writer: *std.Io.Writer) !void {
            try writer.print("{} {s}", .{ self.value, unit_suffix });
        }
    };
}

pub const Nanoseconds = Unit(.Time, 1, "ns");
pub const Microseconds = Unit(.Time, std.time.ns_per_us, "us");
pub const Milliseconds = Unit(.Time, std.time.ns_per_ms, "ms");
pub const Seconds = Unit(.Time, std.time.ns_per_s, "s");
