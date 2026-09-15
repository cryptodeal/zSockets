const constants = @import("constants.zig");
const std = @import("std");

const InternalCallback = @import("../../internal_callback.zig");
const Loop = @import("loop.zig");
const Poll = @import("poll.zig");

fn asyncHandler(c: ?*anyopaque) callconv(.c) void {
    const internal_cb: *InternalCallback = @ptrCast(@alignCast(c));
    internal_cb.cb.?(internal_cb.allocator, internal_cb.io, internal_cb) catch |err| {
        std.debug.print("asyncCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

pub fn createAsync(allocator: std.mem.Allocator, io: std.Io, loop: *Loop, _: bool, comptime Ext: ?type) !*InternalCallback {
    const cb = try InternalCallback.init(allocator, io, loop, Ext);
    cb.expects_loop = true;
    // if (fallthrough) {}
    return cb;
}

pub fn asyncSet(a: *InternalCallback, cb: *const fn (std.mem.Allocator, std.Io, *InternalCallback) anyerror!void) void {
    a.cb = cb;
}

pub fn asyncWakeup(a: *InternalCallback) void {
    std.c.dispatch.async_f(std.c.dispatch.get_main_queue(), a, &asyncHandler);
}

pub fn asyncClose(_: std.mem.Allocator, _: *InternalCallback) void {}
