//! Collection of SMR-based lock-free data structures.
//! Note that "RCU" here does not refer to the Linux implementation, but rather
//! as a generic term to describe concurrent data structures.

const std = @import("std");

pub const HashTableType = @import("hashtable.zig").TableType;

/// Singly-linked list
pub const SList = struct {
    pub const Entry = struct {
        next: std.atomic.Value(usize),
    };
};
