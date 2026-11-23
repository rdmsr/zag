//! Various lock-less "RCU"-style structures for use in SMR algorithms (in ex/).

const std = @import("std");

/// Singly-linked list
pub const SList = struct {
    pub const Entry = struct {
        next: std.atomic.Value(usize),
    };
};
