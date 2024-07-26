const Loop = @import("loop.zig");
const Socket = @import("socket.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Self = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ref: *anyopaque, allocator: Allocator) void,
    getExt: *const fn (ref: *anyopaque) ?*anyopaque,
    getLoop: *const fn (ref: *anyopaque) Loop,
    setOnOpen: *const fn (
        self: *anyopaque,
        on_open: *const fn (allocator: Allocator, s: Socket, is_client: bool, ip: []u8) anyerror!Socket,
    ) void,
    setOnData: *const fn (
        ref: *anyopaque,
        on_data: *const fn (allocator: Allocator, s: Socket, data: []u8) anyerror!Socket,
    ) void,
    setOnWritable: *const fn (
        ref: *anyopaque,
        on_writable: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
    ) void,
    setOnClose: *const fn (
        ref: *anyopaque,
        on_close: *const fn (allocator: Allocator, s: Socket, code: i32, reason: ?*anyopaque) anyerror!Socket,
    ) void,
    setOnTimeout: *const fn (
        ref: *anyopaque,
        on_timeout: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
    ) void,
    setOnEnd: *const fn (
        ref: *anyopaque,
        on_end: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
    ) void,
    setOnConnectErr: *const fn (
        ref: *anyopaque,
        on_connect_err: *const fn (allocator: Allocator, s: Socket, code: i32) anyerror!Socket,
    ) void,
    isLowPriority: *const fn (ref: *anyopaque) bool,
    // create derived connect/listen sockets
    connect: *const fn (
        ref: *anyopaque,
        allocator: Allocator,
        host: ?[:0]const u8,
        port: u64,
        src_host: ?[:0]const u8,
        options: u64,
    ) anyerror!?Socket,
    // TODO(cryptodeal): might need to return a `ListenSocket` type instead?
    listen: *const fn (ref: *anyopaque, allocator: Allocator, host: ?[:0]const u8, port: u64, options: u64) anyerror!?Socket,
    linkSocket: *const fn (ref: *anyopaque, s: Socket) void,
    unlinkSocket: *const fn (ref: *anyopaque, s: Socket) void,
    linkListenSocket: *const fn (ref: *anyopaque, s: Socket) void,
    unlinkListenSocket: *const fn (ref: *anyopaque, s: Socket) void,
    adoptSocket: *const fn (ref: *anyopaque, allocator: Allocator, s: Socket) anyerror!Socket,
};

pub fn deinit(self: *const Self) bool {
    return self.vtable.isClosed(self.ptr);
}

pub fn getExt(self: *const Self, comptime T: type) !?*T {
    return @ptrCast(@alignCast(self.vtable.getExt(self.ptr)));
}

pub fn getLoop(self: *const Self) Loop {
    return self.vtable.getLoop(self.ptr);
}

pub fn setOnOpen(
    self: *const Self,
    on_open: *const fn (allocator: Allocator, s: Socket, is_client: bool, ip: []u8) anyerror!Socket,
) void {
    return self.vtable.setOnOpen(self.ptr, on_open);
}

pub fn setOnData(
    self: *const Self,
    on_data: *const fn (allocator: Allocator, s: Socket, data: []u8) anyerror!Socket,
) void {
    return self.vtable.setOnData(self.ptr, on_data);
}

pub fn setOnWritable(
    self: *const Self,
    on_writable: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
) void {
    return self.vtable.setOnWritable(self.ptr, on_writable);
}

pub fn setOnClose(
    self: *const Self,
    on_close: *const fn (allocator: Allocator, s: Socket, code: i32, reason: ?*anyopaque) anyerror!Socket,
) void {
    return self.vtable.setOnClose(self.ptr, on_close);
}

pub fn setOnTimeout(
    self: *const Self,
    on_timeout: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
) void {
    return self.vtable.setOnTimeout(self.ptr, on_timeout);
}

pub fn setOnEnd(
    self: *const Self,
    on_end: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
) void {
    return self.vtable.setOnEnd(self.ptr, on_end);
}

pub fn setOnConnectErr(
    self: *const Self,
    on_connect_err: *const fn (allocator: Allocator, s: Socket, code: i32) anyerror!Socket,
) void {
    return self.vtable.setOnConnectErr(self.ptr, on_connect_err);
}

pub fn isLowPriority(self: *const Self) bool {
    return self.vtable.isLowPriority(self.ptr);
}

pub fn connect(self: *const Self, allocator: Allocator, host: ?[:0]const u8, port: u64, src_host: ?[:0]const u8, options: u64) !?Socket {
    return self.vtable.connect(self.ptr, allocator, host, port, src_host, options);
}

pub fn listen(self: *const Self, allocator: Allocator, host: ?[:0]const u8, port: u64, options: u64) !?Socket {
    return self.vtable.listen(self.ptr, allocator, host, port, options);
}

pub fn linkSocket(self: *const Self, s: Socket) void {
    return self.vtable.linkSocket(self.ptr, s);
}

pub fn unlinkSocket(self: *const Self, s: Socket) void {
    return self.vtable.unlinkSocket(self.ptr, s);
}

pub fn linkListenSocket(self: *const Self, s: Socket) void {
    return self.vtable.linkListenSocket(self.ptr, s);
}

pub fn unlinkListenSocket(self: *const Self, s: Socket) void {
    return self.vtable.unlinkListenSocket(self.ptr, s);
}

pub fn adoptSocket(self: *const Self, allocator: Allocator, s: Socket) !Socket {
    return self.vtable.adoptSocket(self.ptr, allocator, s);
}

pub fn init(ctx_impl: anytype) Self {
    const Ptr = @TypeOf(ctx_impl);
    const PtrInfo = @typeInfo(Ptr);
    assert(PtrInfo == .Pointer); // Must be a pointer
    assert(PtrInfo.Pointer.size == .One); // Must be a single-item pointer
    assert(@typeInfo(PtrInfo.Pointer.child) == .Struct); // Must point to a struct

    const impl = struct {
        fn deinit(ref: *anyopaque) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.deinit();
        }

        fn getExt(ref: *anyopaque) ?*anyopaque {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.getExt();
        }

        fn getLoop(ref: *anyopaque) Loop {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.getLoop();
        }

        fn setOnOpen(
            ref: *anyopaque,
            on_open: *const fn (allocator: Allocator, s: Socket, is_client: bool, ip: []u8) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnOpen(on_open);
        }

        fn setOnData(
            ref: *anyopaque,
            on_data: *const fn (allocator: Allocator, s: Socket, data: []u8) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnOpen(on_data);
        }

        fn setOnWritable(
            ref: *anyopaque,
            on_writable: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnWritable(on_writable);
        }

        fn setOnClose(
            ref: *anyopaque,
            on_close: *const fn (allocator: Allocator, s: Socket, code: i32, reason: ?*anyopaque) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnClose(on_close);
        }

        fn setOnTimeout(
            ref: *anyopaque,
            on_timeout: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnTimeout(on_timeout);
        }

        fn setOnEnd(
            ref: *anyopaque,
            on_end: *const fn (allocator: Allocator, s: Socket) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnEnd(on_end);
        }

        fn setOnConnectErr(
            ref: *anyopaque,
            on_connect_err: *const fn (allocator: Allocator, s: Socket, code: i32) anyerror!Socket,
        ) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setOnConnectErr(on_connect_err);
        }

        fn isLowPriority(ref: *anyopaque) bool {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.isLowPriority();
        }

        fn connect(ref: *anyopaque, allocator: Allocator, host: ?[:0]const u8, port: u64, src_host: ?[:0]const u8, options: u64) !?Socket {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.connect(allocator, host, port, src_host, options);
        }

        fn listen(ref: *anyopaque, allocator: Allocator, host: ?[:0]const u8, port: u64, options: u64) !?Socket {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.listen(allocator, host, port, options);
        }

        fn linkSocket(ref: *anyopaque, s: Socket) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.linkSocket(s);
        }

        fn unlinkSocket(ref: *anyopaque, s: Socket) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.unlinkSocket(s);
        }

        fn linkListenSocket(ref: *anyopaque, s: Socket) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.linkListenSocket(s);
        }

        fn unlinkListenSocket(ref: *anyopaque, s: Socket) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.unlinkListenSocket(s);
        }

        fn adoptSocket(ref: *anyopaque, allocator: Allocator, s: Socket) !Socket {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.adoptSocket(allocator, s);
        }
    };
    return .{
        .ptr = ctx_impl,
        .vtable = &.{
            .deinit = impl.deinit,
            .getExt = impl.getExt,
            .getLoop = impl.getLoop,
            .setOnOpen = impl.setOnOpen,
            .setOnData = impl.setOnData,
            .setOnWritable = impl.setOnWritable,
            .setOnClose = impl.setOnClose,
            .setOnTimeout = impl.setOnTimeout,
            .setOnEnd = impl.setOnEnd,
            .setOnConnectErr = impl.setOnConnectErr,
            .isLowPriority = impl.isLowPriority,
            .connect = impl.connect,
            .listen = impl.listen,
            .linkSocket = impl.linkSocket,
            .unlinkSocket = impl.unlinkSocket,
            .linkListenSocket = impl.linkListenSocket,
            .unlinkListenSocket = impl.unlinkListenSocket,
            .adoptSocket = impl.adoptSocket,
        },
    };
}
