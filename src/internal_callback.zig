const std = @import("std");
const Extension = @import("extension.zig");
const Loop = @import("eventing/impl.zig").Loop;
const Poll = @import("eventing/impl.zig").Poll;

const Self = @This();

// TODO: potentially remove
// stashes user provided allocator for use when backend
// implementation needs an allocator for callback
allocator: std.mem.Allocator,
io: std.Io,
p: Poll = .{},
loop: *Loop,
expects_loop: bool = false,
leave_poll_ready: bool = false,
cb: ?*const fn (std.mem.Allocator, std.Io, *Self) anyerror!void = null,
server_data: ?*anyopaque = null,
ext: Extension = .{},

pub fn init(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, comptime MaybeT: ?type) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .loop = loop,
        .ext = try Extension.init(allocator, MaybeT),
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.ext.deinit(allocator);
    self.p.deinit(allocator, self.loop);
    allocator.destroy(self);
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}
