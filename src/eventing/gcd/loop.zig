const std = @import("std");
const Extension = @import("../../extension.zig");
const CFRunLoopRun = @import("utils.zig").CFRunLoopRun;
const LoopData = @import("../../internal/loop_data.zig");
const Poll = @import("poll.zig");
const loop_ = @import("../../loop.zig");

const Self = @This();

data: LoopData,
gcd_queue: std.c.dispatch.queue_t,
ext: Extension,

pub fn init(allocator: std.mem.Allocator, io: std.Io, _: ?*anyopaque, wakeup_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, pre_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, post_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, comptime MaybeT: ?type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .data = try LoopData.init(allocator, io, self, wakeup_cb, pre_cb, post_cb),
        .ext = try Extension.init(allocator, MaybeT),
        .gcd_queue = undefined,
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.data.deinit(allocator);
    self.ext.deinit(allocator);
    allocator.destroy(self);
}

pub fn run(self: *Self, _: std.mem.Allocator) !void {
    loop_.integrate(self);
    CFRunLoopRun();
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}
