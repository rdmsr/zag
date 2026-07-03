pub const fireworks = @import("fireworks.zig");
pub const private = @import("private.zig");

const p = private;

pub const WorkItem = p.workqueue.WorkItem;
pub const Console = p.console.Console;

pub const workqueue = struct {
    pub const enqueue = p.workqueue.enqueue;
    pub const enqueue_in = p.workqueue.enqueue_in;
};

pub const console = struct {
    pub const register = p.console.register;
    pub const write = p.console.write;
};
