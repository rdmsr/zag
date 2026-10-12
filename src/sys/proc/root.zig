//! Higher-level process management.

// === Exported modules ===
pub const private = @import("private.zig");

const p = private;

// === Exported types ===
pub const Thread = p.thread.Thread;

// === Exported interfaces ===
pub const thread = struct {
    pub const create_kernel = p.thread.create_kernel;
    pub const exit = p.thread.exit;
    pub const kernel_thread_stack_size = p.thread.kernel_thread_stack_size;
};

pub const init = p.init;
