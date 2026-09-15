const builtin = @import("builtin");
const libuv = if (builtin.os.tag.isDarwin()) @import("darwin_libuv.zig") else @import("libuv");
const std = @import("std");
const loop_ = @import("../../loop.zig");
const LoopData = @import("../../internal/loop_data.zig");
const Extension = @import("../../extension.zig");
const UvWrapper = @import("utils.zig").UvWrapper;

const Self = @This();

// TODO: remove this; currently used for stashing user provided
// allocator in callbacks
allocator: std.mem.Allocator,
io: std.Io,
data: LoopData,
uv_loop: *libuv.uv_loop_t,
is_default: bool,
uv_pre: *UvWrapper(libuv.uv_prepare_t),
uv_check: *UvWrapper(libuv.uv_check_t),
ext: Extension = .{},

fn prepareCb(p: ?*libuv.uv_prepare_t) callconv(.c) void {
    const loop: *Self = @ptrCast(@alignCast(p.?.data));
    loop_.pre(loop.allocator, loop.io, loop) catch |err| {
        std.debug.print("prepareCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

fn checkCb(p: ?*libuv.uv_check_t) callconv(.c) void {
    const loop: *Self = @ptrCast(@alignCast(p.?.data));
    loop_.post(loop.allocator, loop) catch |err| {
        std.debug.print("checkCb Error: {s}\n", .{@errorName(err)});
        std.debug.dumpCurrentStackTrace(.{});
    };
}

pub fn init(allocator: std.mem.Allocator, io: std.Io, hint: ?*anyopaque, wakeup_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, pre_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, post_cb: *const fn (std.mem.Allocator, std.Io, *Self) anyerror!void, comptime MaybeT: ?type) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .uv_loop = if (hint) |h| @ptrCast(@alignCast(h)) else libuv.uv_loop_new(),
        .is_default = hint != null,
        .uv_pre = try UvWrapper(libuv.uv_prepare_t).init(allocator),
        .uv_check = try UvWrapper(libuv.uv_check_t).init(allocator),
        .data = try LoopData.init(allocator, io, self, wakeup_cb, pre_cb, post_cb),
        .ext = try Extension.init(allocator, MaybeT),
    };
    _ = libuv.uv_prepare_init(self.uv_loop, self.uv_pre.ptr());
    _ = libuv.uv_prepare_start(self.uv_pre.ptr(), &prepareCb);
    libuv.uv_unref(@ptrCast(@alignCast(self.uv_pre.ptr())));
    self.uv_pre.ptr().data = self;
    _ = libuv.uv_check_init(self.uv_loop, self.uv_check.ptr());
    libuv.uv_unref(@ptrCast(@alignCast(self.uv_check.ptr())));
    _ = libuv.uv_check_start(self.uv_check.ptr(), &checkCb);
    self.uv_check.ptr().data = self;
    if (hint != null) {
        loop_.integrate(self);
    }
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    libuv.uv_ref(@ptrCast(@alignCast(self.uv_pre.ptr())));
    _ = libuv.uv_prepare_stop(self.uv_pre.ptr());
    self.uv_pre.ptr().data = self.uv_pre;
    libuv.uv_close(@ptrCast(@alignCast(self.uv_pre.ptr())), &UvWrapper(libuv.uv_prepare_t).deinit);

    libuv.uv_ref(@ptrCast(@alignCast(self.uv_check.ptr())));
    _ = libuv.uv_check_stop(self.uv_check.ptr());
    self.uv_check.ptr().data = self.uv_check;
    libuv.uv_close(@ptrCast(@alignCast(self.uv_check.ptr())), &UvWrapper(libuv.uv_check_t).deinit);
    self.data.deinit(allocator);

    if (!self.is_default) {
        _ = libuv.uv_run(self.uv_loop, libuv.UV_RUN_NOWAIT);
        libuv.uv_loop_delete(self.uv_loop);
    }
    self.ext.deinit(allocator);
    allocator.destroy(self);
}

fn pump(self: *Self) void {
    _ = libuv.uv_run(self.uv_loop, libuv.UV_RUN_NOWAIT);
}

pub fn run(self: *Self, _: std.mem.Allocator) !void {
    loop_.integrate(self);
    _ = libuv.uv_run(self.uv_loop, libuv.UV_RUN_DEFAULT);
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}
