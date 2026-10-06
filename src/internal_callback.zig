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
ext: []Extension = &.{},

pub fn init(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, comptime ExtensionTypes: []const type) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .loop = loop,
        .ext = try allocator.alloc(Extension, ExtensionTypes.len),
    };
    errdefer allocator.free(self.ext);
    inline for (0..ExtensionTypes.len) |i| self.ext[i] = Extension.init(allocator, ExtensionTypes[i]) catch |e| {
        for (0..i) |j| self.ext[j].deinit(allocator);
        return e;
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.ext) |*e| e.deinit(allocator);
    allocator.free(self.ext);
    self.p.deinit(allocator, self.loop);
    allocator.destroy(self);
}
