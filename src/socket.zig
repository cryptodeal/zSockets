const build_opts = @import("build_opts");
const std = @import("std");
const bsd = @import("bsd/root.zig");
const Extension = @import("extension.zig");
const openssl = @import("crypto/openssl.zig");
const SocketContext = @import("socket_context.zig");
const Poll = @import("eventing/impl.zig").Poll;
const Loop = @import("eventing/impl.zig").Loop;
const socket_readable = @import("eventing/impl.zig").socket_readable;
const socket_writable = @import("eventing/impl.zig").socket_writable;

const LowPriorityQueueState = @import("internal/internal.zig").LowPriorityQueueState;

const Self = @This();

p: Poll = .{},
timeout: u8 = 255,
long_timeout: u8 = 255,
low_priority_state: LowPriorityQueueState = .not_queued,
context: *SocketContext,
prev: ?*Self = null,
next: ?*Self = null,
ls_field_ptr: bool = false,
is_ssl: bool = false,
ext: Extension = .{},

pub fn adoptInit(allocator: std.mem.Allocator, p: Poll, context: *SocketContext, extension: Extension) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .p = p,
        .context = context,
        .ext = try extension.dupe(allocator),
    };
    return self;
}

pub fn init(allocator: std.mem.Allocator, p: Poll, context: *SocketContext, comptime MaybeT: ?type) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .p = p,
        .context = context,
        .ext = try Extension.init(allocator, MaybeT),
    };
    return self;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator, loop: *Loop) void {
    self.p.deinit(allocator, loop);
    self.ext.deinit(allocator);
    if (build_opts.ssl_impl != .no_ssl) {
        if (self.is_ssl) {
            const ssl_socket: *openssl.SslSocket = @fieldParentPtr("s", self);
            allocator.destroy(ssl_socket);
            return;
        }
    }
    allocator.destroy(self);
}

pub fn localPort(self: *Self, _: bool) !u32 {
    var addr: bsd.AddrT = undefined;
    if (bsd.localAddr(self.p.fd(), &addr)) {
        return @intCast(addr.port);
    } else |err| return err;
}

pub fn remotePort(self: *Self, _: bool) !u32 {
    var addr: bsd.AddrT = undefined;
    if (bsd.remoteAddr(self.p.fd(), &addr)) {
        return @intCast(addr.port);
    } else |err| return err;
}

pub fn shutdownRead(self: *Self, _: bool) void {
    bsd.shutdownSocketRead(self.p.fd());
}

pub fn remoteAddress(self: *Self, _: bool, buf: []u8) ![]u8 {
    var addr: bsd.AddrT = undefined;
    if (bsd.localAddr(self.p.fd(), &addr)) {
        const ip_len: usize = @intCast(addr.ip_length);
        if (buf.len < ip_len) return error.NoSpaceLeft;
        @memcpy(buf[0..ip_len], @as([*]u8, @ptrCast(@alignCast(addr.ip)))[0..ip_len]);
        return buf[0..ip_len];
    } else |err| return err;
}

pub fn setTimeout(self: *Self, _: bool, seconds: u32) void {
    if (seconds != 0) {
        self.timeout = @intCast(@as(u32, @intCast(self.context.timestamp)) + ((seconds + 3) >> 2) % 240);
        // std.debug.print("setTimeout for ptr {d} - timeout = {d}\n", .{ @intFromPtr(self), self.timeout });
    } else {
        self.timeout = 255;
    }
}

pub fn setLongTimeout(self: *Self, _: bool, minutes: u32) void {
    if (minutes != 0) {
        self.long_timeout = @intCast((@as(u32, @intCast(self.context.long_timestamp)) + minutes) % 240);
    } else {
        self.long_timeout = 255;
    }
}

pub fn flush(self: *Self, _: bool) void {
    if (!self.isShutdown(false)) {
        bsd.socketFlush(self.p.fd());
    }
}

pub fn serverNameUserdata(self: *Self, ssl: bool) ?*anyopaque {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocket, @fieldParentPtr("s", self)).getSniUserdata();
        }
    }
    return null;
}

// unused parameter `ssl: bool`
pub fn isClosed(self: *const Self, _: bool) bool {
    return @intFromPtr(self.prev) == @intFromPtr(self.context);
}

pub fn isEstablished(self: *Self, _: bool) bool {
    return self.p.pollType() != .semi_socket;
}

pub fn closeConnecting(self: *Self, _: bool) *Self {
    if (!self.isClosed(false)) {
        self.context.unlinkSocket(self);
        self.p.stop(self.context.loop);
        bsd.closeSocket(self.p.fd());
        self.next = self.context.loop.data.closed_head;
        self.context.loop.data.closed_head = self;
        self.prev = @ptrCast(@alignCast(self.context));
    }
    return self;
}

pub fn close(self: *Self, allocator: std.mem.Allocator, _: bool, code: i32, reason: ?*anyopaque) !*Self {
    if (!self.isClosed(false)) {
        if (self.low_priority_state == .in_queue) {
            if (self.prev) |prev| {
                prev.next = self.next;
            } else {
                self.context.loop.data.low_priority_head = self.next;
            }
            if (self.next) |next| next.prev = self.prev;
            self.prev = null;
            self.next = null;
            self.low_priority_state = .not_queued;
        } else {
            self.context.unlinkSocket(self);
        }
        self.p.stop(self.context.loop);
        bsd.closeSocket(self.p.fd());
        self.next = self.context.loop.data.closed_head;
        self.context.loop.data.closed_head = self;
        self.prev = @ptrCast(@alignCast(self.context));
        return self.context.on_close(allocator, self, code, reason);
    }
    return self;
}

pub fn getNativeHandle(self: *Self, ssl: bool) ?*anyopaque {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocket, @fieldParentPtr("s", self)).getNativeHandle();
        }
    }
    return @ptrFromInt(self.p.fd());
}

pub fn write2(self: *Self, ssl: bool, header: []const u8, payload: []const u8) usize {
    if (self.isClosed(ssl) or self.isShutdown(ssl)) {
        return 0;
    }
    const written = bsd.write2(self.p.fd(), header, payload);
    if (written != @as(isize, @intCast(header.len + payload.len))) self.p.change(self.context.loop, socket_readable | socket_writable);
    return if (written < 0) 0 else @intCast(written);
}

pub fn write(self: *Self, ssl: bool, data: []const u8, msg_more: bool) usize {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocket, @fieldParentPtr("s", self)).write(data, msg_more);
        }
    }
    if (self.isClosed(ssl) or self.isShutdown(ssl)) return 0;
    const written = bsd.send(self.p.fd(), data, msg_more);
    if (written != @as(isize, @intCast(data.len))) {
        self.context.loop.data.last_write_failed = true;
        self.p.change(self.context.loop, socket_readable | socket_writable);
    }
    return if (written < 0) 0 else @intCast(written);
}

pub fn getExt(self: *Self, comptime T: type) ?*T {
    return @ptrCast(@alignCast(self.ext.ptr));
}

// unused parameter `ssl: bool`
pub fn isShutdown(self: *Self, ssl: bool) bool {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            return @as(*openssl.SslSocket, @fieldParentPtr("s", self)).isShutdown();
        }
    }
    return self.p.pollType() == .socket_shutdown;
}

pub fn shutdown(self: *Self, ssl: bool) void {
    if (build_opts.ssl_impl != .no_ssl) {
        if (ssl) {
            @as(*openssl.SslSocket, @fieldParentPtr("s", self)).shutdown();
            return;
        }
    }
    if (!self.isClosed(ssl) and !self.isShutdown(ssl)) {
        self.p.setType(.socket_shutdown);
        self.p.change(self.context.loop, self.p.events() & socket_readable);
        bsd.shutdownSocket(self.p.fd());
    }
}
