const Context = @import("context.zig");
const internal = @import("../internal.zig");
const Poll = @import("poll.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const LowPriorityState = internal.LowPriorityState;

const Self = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    isClosed: *const fn (ref: *anyopaque) bool,
    isEstablished: *const fn (ref: *anyopaque) bool,
    isShutdown: *const fn (ref: *anyopaque) bool,
    close: *const fn (ref: *anyopaque, allocator: Allocator, code: i32, reason: ?*anyopaque) anyerror!Self,
    closeConnecting: *const fn (ref: *anyopaque) anyerror!Self,
    shutdown: *const fn (ref: *anyopaque) anyerror!Self,
    getCtx: *const fn (ref: *anyopaque) ?Context,
    getExt: *const fn (ref: *anyopaque) ?*anyopaque,
    flush: *const fn (ref: *anyopaque) anyerror!void,
    write: *const fn (ref: *anyopaque, data: []const u8, msg_more: bool) anyerror!isize,
    setTimeout: *const fn (ref: *anyopaque, seconds: u32) void,
};

pub fn isClosed(self: *const Self) bool {
    return self.vtable.isClosed(self.ptr);
}

pub fn isEstablished(self: *const Self) bool {
    return self.vtable.isEstablished(self.ptr);
}

pub fn isShutdown(self: *const Self) bool {
    return self.vtable.isShutdown(self.ptr);
}

pub fn close(self: *const Self, allocator: Allocator, code: i32, reason: ?*anyopaque) !Self {
    return self.vtable.close(self.ptr, allocator, code, reason);
}

pub fn closeConnecting(self: *const Self) !Self {
    return self.vtable.closeConnecting(self.ptr);
}

pub fn shutdown(self: *const Self) !Self {
    return self.vtable.shutdown(self.ptr);
}

pub fn getCtx(self: *const Self) !Context {
    return self.vtable.getCtx(self.ptr);
}

pub fn getExt(self: *const Self, comptime T: type) !?*T {
    return @ptrCast(@alignCast(self.vtable.getExt(self.ptr)));
}

pub fn flush(self: *const Self) !void {
    return self.vtable.flush(self.ptr);
}

pub fn write(self: *const Self, data: []const u8, msg_more: bool) !isize {
    return self.vtable.write(self.ptr, data, msg_more);
}

pub fn setTimeout(self: *const Self, seconds: u32) void {
    return self.vtable.setTimeout(self.ptr, seconds);
}

pub fn init(socket_impl: anytype) Self {
    const Ptr = @TypeOf(socket_impl);
    const PtrInfo = @typeInfo(Ptr);
    assert(PtrInfo == .Pointer); // Must be a pointer
    assert(PtrInfo.Pointer.size == .One); // Must be a single-item pointer
    assert(@typeInfo(PtrInfo.Pointer.child) == .Struct); // Must point to a struct

    const impl = struct {
        fn isClosed(ref: *anyopaque) bool {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.isClosed();
        }

        fn isEstablished(ref: *anyopaque) bool {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.isEstablished();
        }

        fn isShutdown(ref: *anyopaque) bool {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.isShutdown();
        }

        fn close(ref: *anyopaque, allocator: Allocator, code: i32, reason: ?*anyopaque) !Self {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.close(allocator, code, reason);
        }

        fn closeConnecting(ref: *anyopaque) !Self {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.closeConnecting();
        }

        fn shutdown(ref: *anyopaque) !Self {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.shutdown();
        }

        fn getCtx(ref: *anyopaque) Context {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.getCtx();
        }

        fn getExt(ref: *anyopaque) ?*anyopaque {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.getExt();
        }

        fn flush(ref: *anyopaque) !void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.flush();
        }

        fn write(ref: *anyopaque, data: []const u8, msg_more: bool) !isize {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.write(data, msg_more);
        }

        fn setTimeout(ref: *anyopaque, seconds: u32) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setTimeout(seconds);
        }
    };
    return .{
        .ptr = socket_impl,
        .vtable = &.{
            .isClosed = impl.isClosed,
            .isEstablished = impl.isEstablished,
            .isShutdown = impl.isShutdown,
            .close = impl.close,
            .closeConnecting = impl.closeConnecting,
            .shutdown = impl.shutdown,
            .getCtx = impl.getCtx,
            .getExt = impl.getExt,
            .flush = impl.flush,
            .write = impl.write,
            .setTimeout = impl.setTimeout,
        },
    };
}
