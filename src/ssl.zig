const build_opts = @import("build_opts");
const std = @import("std");

pub const c = switch (build_opts.ssl_lib) {
    .openssl => @import("crypto/openssl.zig"),
    .wolfssl => @import("crypto/wolfssl.zig"),
    else => @import("crypto/boringssl.zig"),
};

pub fn LoopSslData(comptime Socket: type) type {
    return struct {
        ssl_read_input: []u8,
        ssl_read_output: []u8,
        ssl_read_input_length: usize,
        ssl_read_input_offset: usize,
        ssl_socket: *Socket,
        last_write_was_msg_more: bool,
        msg_more: bool,
        shared_rbio: ?*c.BIO,
        shared_wbio: ?*c.BIO,
        shared_biom: ?*c.BIO_METHOD,
    };
}

pub fn SslCallbacks(comptime Socket: type) type {
    return struct {
        pub fn passphraseCb(buf: [*c]u8, _: c_int, _: c_int, u: ?*anyopaque) callconv(.C) c_int {
            const passphrase: []const u8 = std.mem.span(@as([*c]u8, @ptrCast(@alignCast(u))));
            const buffer: []u8 = @as([*]u8, @ptrCast(@alignCast(buf)))[0..passphrase.len];
            @memcpy(buffer, passphrase);
            // put null at end? no?
            return @intCast(passphrase.len);
        }

        pub fn bioCreate(bio: [*c]c.BIO) callconv(.C) c_int {
            c.BIO_set_init(bio, 1);
            return 1;
        }

        pub fn bioCtrl(_: [*c]c.BIO, cmd: c_int, _: c_long, _: ?*anyopaque) callconv(.C) c_long {
            return switch (cmd) {
                c.BIO_CTRL_FLUSH => 1,
                else => 0,
            };
        }

        pub fn bioWrite(bio: [*c]c.BIO, data: [*c]const u8, len: c_int) callconv(.C) c_int {
            const loop_ssl_data: *LoopSslData(Socket) = @ptrCast(@alignCast(c.BIO_get_data(bio)));
            std.log.debug("bioSCustomWrite", .{});
            loop_ssl_data.last_write_was_msg_more = loop_ssl_data.msg_more or len == 16413;
            const written = loop_ssl_data.ssl_socket.write(false, @as([*]const u8, @ptrCast(@alignCast(data)))[0..@intCast(len)], loop_ssl_data.last_write_was_msg_more) catch {
                c.BIO_set_flags(bio, c.BIO_FLAGS_SHOULD_RETRY | c.BIO_FLAGS_WRITE);
                return -1;
            };
            return @intCast(written);
        }

        pub fn bioRead(bio: [*c]c.BIO, dst: [*c]c_char, length_: c_int) callconv(.C) c_int {
            var length: usize = @intCast(length_);
            const loop_ssl_data: *LoopSslData(Socket) = @ptrCast(@alignCast(c.BIO_get_data(bio)));
            if (loop_ssl_data.ssl_read_input_length == 0) {
                c.BIO_set_flags(bio, c.BIO_FLAGS_SHOULD_RETRY | c.BIO_FLAGS_READ);
                return -1;
            }
            if (length > loop_ssl_data.ssl_read_input_length) {
                length = loop_ssl_data.ssl_read_input_length;
            }
            @memcpy(@as([*]u8, @ptrCast(@alignCast(dst)))[0..length], loop_ssl_data.ssl_read_input[loop_ssl_data.ssl_read_input_offset..][0..length]);
            loop_ssl_data.ssl_read_input_offset += length;
            loop_ssl_data.ssl_read_input_length -= length;
            return @intCast(length);
        }
    };
}
