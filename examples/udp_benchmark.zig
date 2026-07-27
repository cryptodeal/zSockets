const argsParser = @import("args");
const std = @import("std");
const zs = @import("zSockets");

const Options = struct {
    // This declares long options for double hyphen
    protocol: ?[:0]const u8 = null,
    type: [:0]const u8 = "server",
};

var send_buf: *zs.udp.PacketBuffer = undefined;
var messages: f64 = 0;

fn onWakeup(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPre(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn onPost(_: std.mem.Allocator, _: *zs.Loop) !void {}

fn timerCb(_: std.mem.Allocator, _: *zs.Timer) !void {
    std.debug.print("Messages per second: {d}\n", .{messages});
    messages = 0;
}

fn onServerDrain(_: std.mem.Allocator, _: *zs.udp.Socket) !void {}

fn onServerData(_: std.mem.Allocator, s: *zs.udp.Socket, buf: *zs.udp.PacketBuffer, packets: usize) !void {
    for (0..packets) |i| {
        const payload = buf.payload(i);
        // _ = buf.ecn(i);
        const peer_addr = buf.peer(i);

        // var ip_buf: [16]u8 = undefined;
        // const ip = try buf.localIp(i, &ip_buf);
        // std.debug.print("local_ip: {s}\n", .{ip});
        // if (ip.len == 0) {
        //     std.debug.print("We got no ip on received packet!\n", .{});
        //     std.process.exit(0);
        // }

        send_buf.setPayload(i, 0, payload, peer_addr);
        messages += 1;
    }
    _ = try s.send(send_buf, @intCast(packets));
}

pub fn main(init: std.process.Init) !void {
    const args = try argsParser.parseForCurrentProcess(Options, init, .print);
    defer args.deinit();
    // var gpa = std.heap.DebugAllocator(.{}){};
    // defer std.debug.assert(gpa.deinit() == .ok);
    // const allocator = gpa.allocator();

    const allocator = std.heap.smp_allocator;

    var is_client = false;
    var is_ipv6 = false;

    if (args.options.protocol) |p| {
        if (std.mem.eql(u8, p, "ipv6")) {
            std.debug.print("Using IPv6 UDP\n", .{});
            is_ipv6 = true;
        }
    }
    if (std.mem.eql(u8, args.options.type, "client")) {
        std.debug.print("Running as client\n", .{});
        is_client = true;
    } else {
        std.debug.print("Running as server\n", .{});
    }

    // owned by client/server when instantiated
    const receive_buf = try zs.udp.PacketBuffer.init(allocator);

    send_buf = try zs.udp.PacketBuffer.init(allocator);
    defer send_buf.deinit(allocator);

    const loop = try zs.Loop.init(allocator, null, &onWakeup, &onPre, &onPost, null);
    defer loop.deinit(allocator);

    var server: ?*zs.udp.Socket = null;
    defer {
        if (server) |s| s.deinit(allocator);
    }
    var client: ?*zs.udp.Socket = null;
    defer {
        if (client) |c| c.deinit(allocator);
    }
    if (is_client) {
        if (is_ipv6) {
            client = try zs.udp.Socket.init(allocator, loop, receive_buf, &onServerData, &onServerDrain, "::1", 0, null);
        } else {
            client = try zs.udp.Socket.init(allocator, loop, receive_buf, &onServerData, &onServerDrain, "127.0.0.1", 0, null);
        }
    } else {
        if (is_ipv6) {
            server = try zs.udp.Socket.init(allocator, loop, receive_buf, &onServerData, &onServerDrain, "::1", 5678, null);
        } else {
            server = try zs.udp.Socket.init(allocator, loop, receive_buf, &onServerData, &onServerDrain, "127.0.0.1", 5678, null);
        }
    }
    if (server == null and client == null) {
        std.debug.print("Failed to create UDP sockets!\n", .{});
        return error.FailedToCreateUdpSockets;
    }
    var storage = std.mem.zeroes(std.c.sockaddr.storage);
    if (is_ipv6) {
        var addr: *std.c.sockaddr.in6 = @ptrCast(@alignCast(&storage));
        addr.addr[15] = 1;
        addr.port = std.mem.nativeToBig(u16, 5678);
        addr.family = std.c.AF.INET6;
    } else {
        var addr: *std.c.sockaddr.in = @ptrCast(@alignCast(&storage));
        addr.addr = 16777343;
        addr.port = std.mem.nativeToBig(u16, 5678);
        addr.family = std.c.AF.INET;
    }
    if (is_client) {
        const payload: []const u8 = "Hello UDP!";
        inline for (0..40) |i| {
            send_buf.setPayload(i, 0, @constCast(payload), &storage);
        }
        const sent = client.?.send(send_buf, 40) catch |err| {
            std.debug.print("error: {s}\n", .{@errorName(err)});
            return err;
        };
        std.debug.print("Sent initial packets: {d}\n", .{sent});
    }
    const timer = try zs.createTimer(allocator, loop, false, null);
    defer zs.timerClose(allocator, timer);
    zs.timerSet(timer, &timerCb, 1000, 1000);
    try loop.run(allocator);
}
