const std = @import("std");
const zs = @import("../zsockets.zig");

const Allocator = std.mem.Allocator;

const Self = @This();

p: zs.Poll,
loop: *zs.Loop,
expects_loop: bool,
leave_poll_ready: bool,
cb: *const fn (allocator: std.mem.Allocator, cb: *Self) anyerror!void,
_ext: zs.Extension = .{},

pub fn init(allocator: Allocator, comptime Extension: ?type) !*Self {
    const self = try allocator.create(Self);
    if (Extension) |T| self._ext = try zs.Extension.init(allocator, T);
    return self;
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self._ext.deinit(allocator);
    allocator.destroy(self);
}
