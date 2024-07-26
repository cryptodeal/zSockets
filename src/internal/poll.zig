const internal = @import("../internal.zig");
const Loop = @import("loop.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const InternalAsync = internal.InternalAsync;
const InternalCallback = @import("types.zig").InternalCallback;
const PollType = internal.PollType;
const SocketDescriptor = internal.SocketDescriptor;
const Timer = internal.Timer;

const Self = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ref: *anyopaque, allocator: Allocator) void,
    pollType: *const fn (ref: *anyopaque) PollType,
    setPollType: *const fn (ref: *anyopaque, poll_type: PollType) void,
    start: *const fn (ref: *anyopaque, loop: Loop, evnts: u32) anyerror!void,
    stop: *const fn (ref: *anyopaque, loop: Loop) anyerror!void,
    fd: *const fn (ref: *anyopaque) SocketDescriptor,
    events: *const fn (ref: *anyopaque) u32,
    change: *const fn (ref: *anyopaque, loop: Loop, evnts: u32) anyerror!void,
};

pub fn deinit(self: *const Self, allocator: Allocator) void {
    return self.vtable.deinit(self.ptr, allocator);
}

pub fn pollType(self: *const Self) PollType {
    return self.vtable.pollType(self.ptr);
}

pub fn setPollType(self: *const Self, poll_type: PollType) void {
    return self.vtable.setPollType(self.ptr, poll_type);
}

pub fn start(self: *const Self, loop: Loop, evnts: u32) !void {
    return self.vtable.start(self.ptr, loop, evnts);
}

pub fn stop(self: *const Self, loop: Loop) !void {
    return self.vtable.stop(self.ptr, loop);
}

pub fn fd(self: *const Self) SocketDescriptor {
    return self.vtable.fd(self.ptr);
}

pub fn events(self: *const Self) u32 {
    return self.vtable.events(self.ptr);
}

pub fn change(self: *const Self, loop: Loop, evnts: u32) !void {
    return self.vtable.change(self.ptr, loop, evnts);
}

pub fn init(loop_impl: anytype) Self {
    const Ptr = @TypeOf(loop_impl);
    const PtrInfo = @typeInfo(Ptr);
    assert(PtrInfo == .Pointer); // Must be a pointer
    assert(PtrInfo.Pointer.size == .One); // Must be a single-item pointer
    const Child = PtrInfo.Pointer.child;
    assert(@typeInfo(Child) == .Struct); // Must point to a struct

    const impl = struct {
        fn deinit(ref: *anyopaque, allocator: Allocator) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.createTimer(allocator);
        }

        fn pollType(ref: *anyopaque) PollType {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.pollType();
        }

        fn setPollType(ref: *anyopaque, poll_type: PollType) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setPollType(poll_type);
        }

        fn start(ref: *anyopaque, loop: Loop, evnts: u32) anyerror!void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.start(loop, evnts);
        }

        fn stop(ref: *anyopaque, loop: Loop) anyerror!void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.stop(loop);
        }

        fn fd(ref: *anyopaque) SocketDescriptor {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.fd();
        }

        fn events(ref: *anyopaque) u32 {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.events();
        }

        fn change(ref: *anyopaque, loop: Loop, evnts: u32) anyerror!void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.change(loop, evnts);
        }
    };
    return .{
        .ptr = loop_impl,
        .vtable = &.{
            .deinit = impl.deinit,
            .pollType = impl.pollType,
            .setPollType = impl.setPollType,
            .start = impl.start,
            .stop = impl.stop,
            .fd = impl.fd,
            .events = impl.events,
            .change = impl.change,
        },
    };
}
