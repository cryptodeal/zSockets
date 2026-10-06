const bsd = @import("../bsd/root.zig");
const build_opts = @import("build_opts");
const std = @import("std");
const Extension = @import("../extension.zig");
const Poll = @import("../eventing/impl.zig").Poll;
const socket_readable = @import("../eventing/impl.zig").socket_readable;
const socket_writable = @import("../eventing/impl.zig").socket_writable;

const Socket = @import("../socket.zig");
const SocketContext = @import("../socket_context.zig");

pub fn EnumError(comptime E: type) type {
    switch (@typeInfo(E)) {
        .@"enum" => {
            var T: type = error{};
            for (std.meta.fields(E)) |enum_field| {
                T = T || @TypeOf(@field(anyerror, enum_field.name));
            }
            return T;
        },
        else => @compileError("EnumError only accepts enum types."),
    }
}

pub const Timer = anyopaque;

pub const PollType = enum(u8) {
    socket = 0,
    socket_shutdown = 1,
    semi_socket = 2,
    callback = 3,
    polling_out = 4,
    polling_in = 8,
    _,
};

pub const LowPriorityQueueState = enum(u8) {
    not_queued,
    in_queue,
    prev_queued,
};

pub fn isLowPriority(_: *Socket) LowPriorityQueueState {
    return .not_queued;
}

pub fn adoptAcceptedSocket(allocator: std.mem.Allocator, io: std.Io, socket: *Socket, context: *SocketContext, accepted_fd: std.posix.fd_t, addr_ip: []u8, extensions: []Extension) !void {
    socket.* = .{
        .context = context,
        .ext = try allocator.alloc(Extension, extensions.len),
    };
    errdefer allocator.free(socket.ext);
    for (0..extensions.len) |i| socket.ext[i] = extensions[i].dupe(allocator) catch |e| {
        for (0..i) |j| socket.ext[j].deinit(allocator);
        return e;
    };
    try socket.p.create(allocator, io, context.loop, false, &.{});
    socket.p.init(accepted_fd, .socket);
    socket.p.start(context.loop, socket_readable);
    bsd.socketNoDelay(accepted_fd, true);
    context.linkSocket(socket);
    _ = try context.on_open(allocator, io, socket, false, addr_ip);
}

pub fn adoptAcceptedSocketNewExtensions(allocator: std.mem.Allocator, io: std.Io, socket: *Socket, context: *SocketContext, accepted_fd: std.posix.fd_t, addr_ip: []u8, comptime ExtensionTypes: []const type) !void {
    socket.* = .{
        .context = context,
        .ext = try allocator.alloc(Extension, ExtensionTypes.len),
    };
    errdefer allocator.free(socket.ext);
    inline for (0..ExtensionTypes.len) |i| socket.ext[i] = Extension.init(allocator, ExtensionTypes[i]) catch |e| {
        for (0..i) |j| socket.ext[j].deinit(allocator);
        return e;
    };
    try socket.p.create(allocator, io, context.loop, false, &.{});
    socket.p.init(accepted_fd, .socket);
    socket.p.start(context.loop, socket_readable);
    bsd.socketNoDelay(accepted_fd, true);
    context.linkSocket(socket);
    _ = try context.on_open(allocator, io, socket, false, addr_ip);
}

pub fn connect(allocator: std.mem.Allocator, io: std.Io, context: *SocketContext, socket: *Socket, host: [:0]const u8, port: u32, source_host: ?[:0]const u8, options: u32, comptime ExtensionTypes: []const type) !void {
    const connect_socket_fd = try bsd.createConnectSocket(host, port, source_host, options);
    socket.* = .{
        .context = context,
        .ext = try allocator.alloc(Extension, ExtensionTypes.len),
    };
    errdefer allocator.free(socket.ext);
    inline for (0..ExtensionTypes.len) |i| socket.ext[i] = Extension.init(allocator, ExtensionTypes[i]) catch |e| {
        for (0..i) |j| socket.ext[j].deinit(allocator);
        return e;
    };
    try socket.p.create(allocator, io, context.loop, false, &.{});
    socket.p.init(connect_socket_fd, .semi_socket);
    socket.p.start(context.loop, socket_writable);
    context.linkSocket(socket);
}

pub fn connectUnix(allocator: std.mem.Allocator, io: std.Io, context: *SocketContext, socket: *Socket, server_path: [:0]const u8, options: u32, comptime ExtensionTypes: []const type) !void {
    const connect_socket_fd = try bsd.createConnectSocketUnix(server_path, options);
    socket.* = .{
        .context = context,
        .ext = try allocator.alloc(Extension, ExtensionTypes.len),
    };
    errdefer allocator.free(socket.ext);
    inline for (0..ExtensionTypes.len) |i| socket.ext[i] = Extension.init(allocator, ExtensionTypes[i]) catch |e| {
        for (0..i) |j| socket.ext[j].deinit(allocator);
        return e;
    };
    try socket.p.create(allocator, io, context.loop, false, &.{});
    socket.p.init(connect_socket_fd, .semi_socket);
    socket.p.start(context.loop, socket_writable);
    context.linkSocket(socket);
}
