const builtin = @import("builtin");
const std = @import("std");
const constants = @import("constants.zig");
const libuv = if (builtin.os.tag.isDarwin()) @import("darwin_libuv.zig") else @import("libuv");
const Extension = @import("../../extension.zig");
const Loop = @import("loop.zig");
const loop_ = @import("../../loop.zig");
const PollType = @import("../../internal/internal.zig").PollType;

const Self = @This();

pub const CallbackPayload = struct {
    allocator: std.mem.Allocator,
    poll: *Self,

    pub fn init(allocator: std.mem.Allocator, poll: *Self) !*CallbackPayload {
        const self: *CallbackPayload = try allocator.create(CallbackPayload);
        self.* = .{
            .allocator = allocator,
            .poll = poll,
        };
        return self;
    }

    pub fn deinit(self: *CallbackPayload) void {
        self.allocator.destroy(self);
    }
};

io: std.Io = undefined,
uv_p: ?*libuv.uv_poll_t = null,
fd_: std.posix.fd_t = undefined,
poll_type: PollType = undefined,
ext: Extension = .{},
callback_payload: *CallbackPayload = undefined,

fn pollCb(p: ?*libuv.uv_poll_t, status: c_int, events_: c_int) callconv(.c) void {
    const payload: *CallbackPayload = @ptrCast(@alignCast(p.?.data));
    loop_.internalDispatchReadyPoll(payload.allocator, payload.poll.io, payload.poll, @intCast(@intFromBool(status < 0)), @intCast(events_)) catch |err| {
        std.debug.print("pollCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

fn closeCbFreePoll(h: ?*libuv.uv_handle_t) callconv(.c) void {
    if (h.?.data) |data| {
        const payload: *CallbackPayload = @ptrCast(@alignCast(data));
        payload.allocator.destroy(@as(*libuv.uv_poll_t, @ptrCast(@alignCast(h))));
        payload.deinit();
    }
}

pub fn create(self: *Self, allocator: std.mem.Allocator, io: std.Io, _: *Loop, _: bool, comptime Ext: ?type) !void {
    // TODO: set `uv_p.data` as pointer to self
    self.* = .{
        .io = io,
        .uv_p = try allocator.create(libuv.uv_poll_t),
        .ext = try Extension.init(allocator, Ext),
        .callback_payload = try CallbackPayload.init(allocator, self),
    };
    self.uv_p.?.data = self.callback_payload;
}

pub fn init(self: *Self, fd_: std.posix.fd_t, poll_type: PollType) void {
    self.poll_type = poll_type;
    self.fd_ = fd_;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator, _: *Loop) void {
    if (self.uv_p) |uvp| {
        if (libuv.uv_is_closing(@ptrCast(@alignCast(uvp))) != 0) {
            uvp.data = self.callback_payload;
        } else {
            std.debug.print("\nfreed poll: 0x{x}", .{@intFromPtr(self)});
            self.callback_payload.deinit();
            allocator.destroy(uvp);
        }
    } else {
        self.callback_payload.deinit();
    }
    self.ext.deinit(allocator);
}

pub fn resize(self: *Self, _: *Loop) void {
    self.uv_p.?.data = self.callback_payload;
}

pub fn start(self: *Self, loop: *Loop, events_: u32) void {
    self.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if (events_ & constants.socket_readable != 0) @intFromEnum(PollType.polling_in) else 0) | (if (events_ & constants.socket_writable != 0) @intFromEnum(PollType.polling_out) else 0));
    _ = libuv.uv_poll_init_socket(loop.uv_loop, self.uv_p, self.fd_);
    _ = libuv.uv_poll_start(self.uv_p, @intCast(events_), &pollCb);
}

pub fn events(self: *const Self) u32 {
    return (if (@intFromEnum(self.poll_type) & @intFromEnum(PollType.polling_in) != 0) @as(u32, constants.socket_readable) else 0) | (if (@intFromEnum(self.poll_type) & @intFromEnum(PollType.polling_out) != 0) @as(u32, constants.socket_writable) else 0);
}

pub fn change(self: *Self, _: *Loop, events_: u32) void {
    if (self.events() != events_) {
        self.poll_type = @enumFromInt(@intFromEnum(self.pollType()) | (if (events_ & constants.socket_readable != 0) @intFromEnum(PollType.polling_in) else 0) | (if (events_ & constants.socket_writable != 0) @intFromEnum(PollType.polling_out) else 0));
        _ = libuv.uv_poll_start(self.uv_p, @intCast(events_), &pollCb);
    }
}

pub fn stop(self: *Self, _: *Loop) void {
    _ = libuv.uv_poll_stop(self.uv_p);
    self.uv_p.?.data = null;
    libuv.uv_close(@ptrCast(@alignCast(self.uv_p)), &closeCbFreePoll);
}

fn acceptEvent(_: *Self) usize {
    return 0;
}

pub fn pollType(self: *const Self) PollType {
    return @enumFromInt(@intFromEnum(self.poll_type) & 3);
}

pub fn setType(self: *Self, poll_type: PollType) void {
    self.poll_type = @enumFromInt(@intFromEnum(poll_type) | (@intFromEnum(self.poll_type) & 12));
}

pub fn fd(self: *Self) std.posix.fd_t {
    return self.fd_;
}
