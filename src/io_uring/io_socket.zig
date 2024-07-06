const internal = @import("internal.zig");
const std = @import("std");

const Socket = internal.Socket;
const SocketCtx = internal.SocketCtx;

// shared with ssl

pub fn socketLocalPort(ssl: c_int, s: *Socket) c_int {
    _ = ssl; // autofix
    _ = s; // autofix
    return 0;
}

pub fn socketRemotePort(ssl: c_int, s: *Socket) c_int {
    _ = ssl; // autofix
    _ = s; // autofix
    return 0;
}

pub fn socketShutdownRead(ssl: c_int, s: *Socket) void {
    _ = ssl; // autofix
    _ = s; // autofix
}

pub fn socketRemoteAddress(ssl: c_int, s: *Socket, buf: []u8) void {
    _ = ssl; // autofix
    _ = s; // autofix
    _ = buf; // autofix
}

pub fn socketCtx(ssl: c_int, s: *Socket) *SocketCtx {
    _ = ssl; // autofix
    return s.ctx;
}

pub fn socketTimeout(ssl: c_int, s: *Socket, seconds: c_uint) void {
    _ = ssl; // autofix
    if (seconds != 0) {
        s.timeout = (s.ctx.timestamp + ((seconds + 3) >> 2)) % 240;
    } else {
        s.timeout = 255;
    }
}

pub fn socketLongTimeout(ssl: c_int, s: *Socket, minutes: c_uint) void {
    _ = ssl; // autofix
    if (minutes != 0) {
        s.long_timeout = (s.ctx.long_timestamp + minutes) % 240;
    } else {
        s.long_timeout = 255;
    }
}

pub fn socketFlush(ssl: c_int, s: *Socket) void {
    _ = ssl; // autofix
    _ = s; // autofix
}

pub fn socketIsClosed(ssl: c_int, s: *Socket) c_int {
    _ = ssl; // autofix
    _ = s; // autofix
    return 0;
}

pub fn socketIsEstablished(ssl: c_int, s: *Socket) c_int {
    _ = ssl; // autofix
    _ = s; // autofix
    return 1;
}

/// Same as `socketClose` but does not emit `on_close` event.
pub fn socketCloseConnecting(ssl: c_int, s: *Socket) *Socket {
    _ = ssl; // autofix
    return s;
}

pub fn socketWrite2(ssl: c_int, s: *Socket, header: []const u8, payload: []const u8) c_int {
    _ = ssl; // autofix
    _ = s; // autofix
    _ = header; // autofix
    _ = payload; // autofix
    std.process.exit(1);
}

pub fn socketSendBuffer(ssl: c_int, s: *Socket) []const u8 {
    _ = ssl; // autofix
    return &s.send_buf;
}

/// Same as `socketCloseConnecting` but emits `on_close` event.
pub fn socketClose(ssl: c_int, s: *Socket, code: c_int, reason: ?*anyopaque) *Socket {
    _ = ssl; // autofix
    _ = code; // autofix
    _ = reason; // autofix
    return s;
}

// Not shared with ssl
pub fn socketGetNativeHandle(ssl: c_int, s: *Socket) c_int {
    _ = ssl; // autofix
    _ = s; // autofix
    return 0;
}

pub fn socketWrite(ssl: c_int, s: *Socket, data: []const u8, msg_more: c_int) c_int {
    _ = ssl; // autofix
    _ = msg_more; // autofix
    std.log.debug("writing on socket now", .{});

    if (!std.mem.eql(u8, data, s.send_buf[0..data.len])) {
        std.log.debug("WTF", .{});
        @memcpy(s.send_buf[0..data.len], data);
    }
}
