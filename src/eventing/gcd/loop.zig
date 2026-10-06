const std = @import("std");
const Extension = @import("../../extension.zig");
const CFRunLoopRun = @import("utils.zig").CFRunLoopRun;
const LoopData = @import("../../internal/loop_data.zig");
const Poll = @import("poll.zig");
const loop_ = @import("../../loop.zig");

const Self = @This();

data: LoopData,
gcd_queue: std.c.dispatch.queue_t,
ext: []Extension = &.{},

pub fn init(allocator: std.mem.Allocator, io: std.Io, _: ?*anyopaque, wakeup_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, pre_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, post_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, comptime ExtensionTypes: []const type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .data = try LoopData.init(allocator, io, self, wakeup_cb, pre_cb, post_cb),
        .ext = try allocator.alloc(Extension, ExtensionTypes.len),
        .gcd_queue = undefined,
    };
    errdefer allocator.free(self.ext);
    errdefer self.data.deinit(allocator);
    inline for (0..ExtensionTypes.len) |i| self.ext[i] = Extension.init(allocator, ExtensionTypes[i]) catch |e| {
        for (0..i) |j| self.ext[j].deinit(allocator);
        return e;
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.data.deinit(allocator);
    for (self.ext) |*e| e.deinit(allocator);
    allocator.free(self.ext);
    allocator.destroy(self);
}

pub fn run(self: *Self, _: std.mem.Allocator, _: std.Io) !void {
    loop_.integrate(self);
    CFRunLoopRun();
}
