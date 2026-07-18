pub const fireworks = @import("fireworks.zig");
pub const private = @import("private.zig");

const p = private;

pub const WorkItem = p.work.WorkItem;
pub const Console = p.console.Console;

pub const work = struct {
    pub const enqueue = p.work.enqueue;
    pub const enqueue_in = p.work.enqueue_in;
};

pub const console = struct {
    pub const register = p.console.register;
    pub const write = p.console.write;
};
