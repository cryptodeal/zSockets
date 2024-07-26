const internal = @import("../internal.zig");
const Poll = @import("poll.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const InternalAsync = internal.InternalAsync;
const InternalCallback = @import("types.zig").InternalCallback;
const Timer = internal.Timer;

const Self = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    createTimer: *const fn (ref: *anyopaque, allocator: Allocator, fallthrough: bool) anyerror!*Timer,
    destroyTimer: *const fn (allocator: Allocator, timer: *Timer) anyerror!void,
    createAsync: *const fn (ref: *anyopaque, allocator: Allocator, fallthrough: bool) anyerror!*InternalAsync,
    closeAsync: *const fn (allocator: Allocator, a: *InternalAsync) anyerror!void,
    asyncWakeup: *const fn (ref: *anyopaque) anyerror!void,
    getReadyPoll: *const fn (ref: *anyopaque, index: usize) ?*anyopaque,
    setReadyPoll: *const fn (ref: *anyopaque, index: usize, poll: ?*anyopaque) void,
    updatePendingReadyPolls: *const fn (ref: *anyopaque, old_poll: Poll, new_poll: ?Poll, old_events: u32, new_events: u32) void,
    run: *const fn (ref: *anyopaque, allocator: Allocator) anyerror!void,
};

pub fn createTimer(self: *const Self, allocator: Allocator, fallthrough: bool) !*Timer {
    return self.vtable.createTimer(self.ptr, allocator, fallthrough);
}

pub fn destroyTimer(self: *const Self, allocator: Allocator, timer: *Timer) !void {
    return self.vtable.destroyTimer(allocator, timer);
}

pub fn createAsync(self: *const Self, allocator: Allocator, fallthrough: bool) !*InternalAsync {
    return self.vtable.createAsync(self.ptr, allocator, fallthrough);
}

pub fn closeAsync(self: *const Self, allocator: Allocator, a: *InternalAsync) !void {
    return self.vtable.closeAsync(allocator, a);
}

pub fn asyncWakeup(self: *const Self) !void {
    return self.vtable.asyncWakeup(self.ptr);
}

pub fn getReadyPoll(self: *const Self, index: usize, comptime T: type) ?Self {
    if (self.vtable.getReadyPoll(self.ptr, index)) |poll| {
        return Self.init(@as(*T, @ptrCast(@alignCast(poll))));
    } else return null;
}

pub fn setReadyPoll(self: *const Self, index: usize, poll: ?*anyopaque) void {
    return self.vtable.setReadyPoll(self.ptr, index, poll);
}

pub fn updatePendingReadyPolls(self: *const Self, old_poll: Poll, new_poll: ?Poll, old_events: u32, new_events: u32) void {
    return self.vtable.updatePendingReadyPolls(self.ptr, old_poll, new_poll, old_events, new_events);
}

pub fn run(self: *const Self, allocator: Allocator) !void {
    return self.vtable.run(self.ptr, allocator);
}

pub fn init(loop_impl: anytype) Self {
    const Ptr = @TypeOf(loop_impl);
    const PtrInfo = @typeInfo(Ptr);
    assert(PtrInfo == .Pointer); // Must be a pointer
    assert(PtrInfo.Pointer.size == .One); // Must be a single-item pointer
    const Child = PtrInfo.Pointer.child;
    assert(@typeInfo(Child) == .Struct); // Must point to a struct

    const impl = struct {
        fn createTimer(ref: *anyopaque, allocator: Allocator, fallthrough: bool) !*Timer {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.createTimer(allocator, fallthrough);
        }

        fn createAsync(ref: *anyopaque, allocator: Allocator, fallthrough: bool) !*InternalAsync {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.createAsync(allocator, fallthrough);
        }

        fn asyncWakeup(ref: *anyopaque) !void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.asyncWakeup();
        }

        fn getReadyPoll(ref: *anyopaque, index: usize) ?*anyopaque {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.getReadyPoll(index);
        }

        fn setReadyPoll(ref: *anyopaque, index: usize, poll: ?*anyopaque) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.setReadyPoll(index, poll);
        }

        fn updatePendingReadyPolls(ref: *anyopaque, old_poll: Poll, new_poll: ?Poll, old_events: u32, new_events: u32) void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.updatePendingReadyPolls(old_poll, new_poll, old_events, new_events);
        }

        fn run(ref: *anyopaque, allocator: Allocator) !void {
            const self: Ptr = @ptrCast(@alignCast(ref));
            return self.run(allocator);
        }
    };
    return .{
        .ptr = loop_impl,
        .vtable = &.{
            .createTimer = impl.createTimer,
            .destroyTimer = Child.destroyTimer,
            .createAsync = impl.createAsync,
            .closeAsync = Child.closeAsync,
            .asyncWakeup = impl.asyncWakeup,
            .getReadyPoll = impl.getReadyPoll,
            .setReadyPoll = impl.setReadyPoll,
            .updatePendingReadyPolls = impl.updatePendingReadyPolls,
            .run = impl.run,
        },
    };
}
