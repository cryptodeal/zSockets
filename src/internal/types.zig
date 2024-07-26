const Loop = @import("loop.zig");
const Poll = @import("poll.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const InternalCallback = struct {
    const Self = @This();
    p: Poll,
    loop: Loop,
    cb_expects_the_loop: bool,
    leave_poll_ready: bool,
    cb: *const fn (allocator: Allocator, self: *Self) anyerror!void,
};
