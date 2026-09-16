const constants = @import("constants.zig");
const std = @import("std");
const Loop = @import("loop.zig");
const Extension = @import("../../extension.zig");
const PollType = @import("../../internal/internal.zig").PollType;
const loop_ = @import("../../loop.zig");

const Self = @This();

// TODO: remove this; currently used for stashing user provided
// allocator in callbacks
allocator: std.mem.Allocator = undefined,
io: std.Io = undefined,
events_: u32 = 0,
gcd_read: std.c.dispatch.source_t = undefined,
gcd_write: std.c.dispatch.source_t = undefined,
fd_: std.posix.fd_t = undefined,
poll_type: PollType = .socket,
ext: Extension = .{},

fn gcdReadHandler(p: ?*anyopaque) callconv(.c) void {
    const poll: *Self = @ptrCast(@alignCast(p));
    loop_.internalDispatchReadyPoll(poll.allocator, poll.io, poll, 0, constants.socket_readable) catch |err| {
        std.debug.print("gcdReadHandler Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

fn gcdWriteHandler(p: ?*anyopaque) callconv(.c) void {
    const poll: *Self = @ptrCast(@alignCast(p));
    loop_.internalDispatchReadyPoll(poll.allocator, poll.io, poll, 0, constants.socket_writable) catch |err| {
        std.debug.print("gcdWriteHandler Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

pub fn create(self: *Self, allocator: std.mem.Allocator, io: std.Io, _: *Loop, _: bool, comptime Ext: ?type) !void {
    self.* = .{
        .allocator = allocator,
        .io = io,
        .ext = try Extension.init(allocator, Ext),
    };
}

pub fn init(self: *Self, fd_: std.posix.fd_t, poll_type: PollType) void {
    self.poll_type = poll_type;
    self.fd_ = fd_;
    self.gcd_read = std.c.dispatch.source_create(std.c.dispatch.SOURCE_TYPE_READ, @intCast(self.fd_), @bitCast(@as(usize, 0)), std.c.dispatch.get_main_queue()).?;
    std.c.dispatch.set_context(self.gcd_read.as_object(), self);
    std.c.dispatch.source_set_event_handler_f(self.gcd_read, &gcdReadHandler);
    std.c.dispatch.source_set_cancel_handler_f(self.gcd_read, &gcdReadHandler);
    self.gcd_write = std.c.dispatch.source_create(std.c.dispatch.SOURCE_TYPE_WRITE, @intCast(self.fd_), @bitCast(@as(usize, 0)), std.c.dispatch.get_main_queue()).?;
    std.c.dispatch.set_context(self.gcd_write.as_object(), self);
    std.c.dispatch.source_set_event_handler_f(self.gcd_write, &gcdWriteHandler);
    std.c.dispatch.source_set_cancel_handler_f(self.gcd_write, &gcdWriteHandler);
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator, loop: *Loop) void {
    self.change(loop, constants.socket_readable | constants.socket_writable);
    std.c.dispatch.release(self.gcd_read.as_object());
    std.c.dispatch.release(self.gcd_write.as_object());
    self.ext.deinit(allocator);
}

pub fn resize(_: *Self, _: *Loop) void {
    // TODO: might need to implement stuff here
}

pub fn start(self: *Self, _: *Loop, events_: u32) void {
    self.events_ = events_;
    if ((events_ & constants.socket_readable) != 0) {
        std.c.dispatch.@"resume"(self.gcd_read.as_object());
    }
    if ((events_ & constants.socket_writable) != 0) {
        std.c.dispatch.@"resume"(self.gcd_write.as_object());
    }
}

pub fn change(self: *Self, _: *Loop, events_: u32) void {
    const old_events = self.events_;
    if ((old_events & constants.socket_readable) != (events_ & constants.socket_readable)) {
        if ((old_events & constants.socket_readable) != 0) {
            std.c.dispatch.@"suspend"(self.gcd_read.as_object());
        } else {
            std.c.dispatch.@"resume"(self.gcd_read.as_object());
        }
    }
    if ((old_events & constants.socket_writable) != (events_ & constants.socket_writable)) {
        if ((old_events & constants.socket_writable) != 0) {
            std.c.dispatch.@"suspend"(self.gcd_write.as_object());
        } else {
            std.c.dispatch.@"resume"(self.gcd_write.as_object());
        }
    }
    self.events_ = events_;
}

pub fn stop(self: *Self, _: *Loop) void {
    if ((self.events_ & constants.socket_readable) != 0) {
        std.c.dispatch.@"suspend"(self.gcd_read.as_object());
    }
    if ((self.events_ & constants.socket_writable) != 0) {
        std.c.dispatch.@"suspend"(self.gcd_write.as_object());
    }
    self.events_ = 0;
}

pub fn events(self: *const Self) u32 {
    return self.events_;
}

pub fn acceptEvent(_: *Self) usize {
    return 0;
}

pub fn pollType(self: *const Self) PollType {
    return @enumFromInt(@intFromEnum(self.poll_type) & 3);
}

pub fn setType(self: *Self, poll_type: PollType) void {
    self.poll_type = poll_type;
}

pub fn fd(self: *Self) std.posix.fd_t {
    return self.fd_;
}
