const builtin = @import("builtin");
const constants = @import("constants.zig");
const std = @import("std");
const libuv = if (builtin.os.tag.isDarwin()) @import("darwin_libuv.zig") else @import("libuv");

const InternalCallback = @import("../../internal_callback.zig");
const Loop = @import("loop.zig");
const Poll = @import("poll.zig");

fn asyncCb(a: ?*libuv.uv_async_t) callconv(.c) void {
    const cb: *InternalCallback = @ptrCast(@alignCast(a.?.data));
    cb.cb.?(cb.allocator, cb.io, cb) catch |err| {
        std.debug.print("asyncCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

fn closeCbFree(t: ?*libuv.uv_handle_t) callconv(.c) void {
    const cb: *InternalCallback = @ptrCast(@alignCast(t.?.data));
    const uv_async: ?*libuv.uv_async_t = @ptrCast(@alignCast(cb.server_data));
    cb.allocator.destroy(uv_async.?);
    cb.deinit(cb.allocator);
}

pub fn createAsync(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, _: bool, comptime Ext: ?type) !*InternalCallback {
    const cb = try InternalCallback.init(allocator, io, loop, Ext);
    cb.p.callback_payload = try Poll.CallbackPayload.init(allocator, &cb.p);
    cb.loop = loop;
    cb.server_data = try allocator.create(libuv.uv_async_t);
    return cb;
}

pub fn asyncSet(a: *InternalCallback, cb: *const fn (std.mem.Allocator, std.Io, *InternalCallback) anyerror!void) void {
    a.cb = cb;
    const uv_async: ?*libuv.uv_async_t = @ptrCast(@alignCast(a.server_data));
    _ = libuv.uv_async_init(a.loop.uv_loop, uv_async, &asyncCb);
    libuv.uv_unref(@ptrCast(@alignCast(uv_async)));
    uv_async.?.data = a;
}

pub fn asyncWakeup(a: *InternalCallback) void {
    const uv_async: ?*libuv.uv_async_t = @ptrCast(@alignCast(a.server_data));
    _ = libuv.uv_async_send(uv_async);
}

pub fn asyncClose(_: std.mem.Allocator, a: *InternalCallback) void {
    const uv_async: ?*libuv.uv_async_t = @ptrCast(@alignCast(a.server_data));
    libuv.uv_ref(@ptrCast(@alignCast(uv_async)));
    uv_async.?.data = a;
    libuv.uv_close(@ptrCast(@alignCast(uv_async)), &closeCbFree);
}
