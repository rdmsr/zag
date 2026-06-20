pub const fireworks = @import("fireworks.zig");
pub const private = @import("private.zig");

const p = private;

pub const WorkItem = p.workqueue.WorkItem;

pub const workqueue = struct {
    pub const enqueue = p.workqueue.enqueue;
};
