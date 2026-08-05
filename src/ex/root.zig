pub const private = @import("private.zig");

const p = private;

pub const WorkItem = p.work.WorkItem;
pub const DelayedWorkItem = p.work.DelayedWorkItem;
pub const Console = p.console.Console;
pub const InternedString = p.string.InternedString;

pub const init = p.init;

pub const work = struct {
    pub const enqueue = p.work.enqueue;
    pub const enqueue_in = p.work.enqueue_in;
};

pub const console = struct {
    pub const register = p.console.register;
    pub const write = p.console.write;
};

pub const string = struct {
    pub const retain = p.string.retain;
    pub const release = p.string.release;
};
