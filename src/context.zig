const build_opts = @import("build_opts");
const bsd = @import("bsd.zig");
const c = @import("ssl.zig");
const internal = @import("internal.zig");
const sni = @import("crypto/sni_tree.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const PollT = @import("events.zig").PollT;
const LowPriorityState = internal.LowPriorityState;
const RECV_BUFFER_LENGTH = internal.RECV_BUFFER_LENGTH;
const RECV_BUFFER_PADDING = internal.RECV_BUFFER_PADDING;
const SocketCtxOpts = internal.SocketCtxOpts;
const SocketDescriptor = internal.SocketDescriptor;
const SOCKET_READABLE = internal.SOCKET_READABLE;

pub fn SocketCtx(
    comptime ssl: bool,
    comptime SocketCtxExt: type,
    comptime Loop: type,
    comptime Poll: type,
    comptime Socket: type,
) type {
    _ = Poll; // autofix
    const BaseContext = struct {
        const Self = @This();

        loop: *Loop,
        global_tick: u32,
        timestamp: u8 = 0,
        long_timestamp: u8 = 0,
        head_sockets: ?*Socket = null,
        head_listen_sockets: ?*Socket = null,
        iterator: ?*Socket = null,
        prev: ?*Self = null,
        next: ?*Self = null,
        on_pre_open: ?*const fn (fd: SocketDescriptor) SocketDescriptor = null,
        on_open: *const fn (allocator: Allocator, s: *Socket, is_client: bool, ip: []u8) anyerror!*Socket,
        on_data: *const fn (allocator: Allocator, s: *Socket, data: []u8) anyerror!*Socket,
        on_writable: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
        on_close: *const fn (allocator: Allocator, s: *Socket, code: i32, reason: ?*anyopaque) anyerror!*Socket,
        on_socket_timeout: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
        on_socket_long_timeout: ?*const fn (allocator: Allocator, s: *Socket) anyerror!*Socket = null,
        on_connect_error: ?*const fn (s: *Socket, code: i32) anyerror!*Socket = null,
        on_end: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
        is_low_prio: *const fn (s: *Socket) LowPriorityState = &isLowPriorityHandler,

        // User should not call this function directly.
        pub fn internalInit(loop: *Loop) Self {
            var self: Self = .{
                .loop = loop,
            };
            self.internalLinkLoop(loop);
            return self;
        }

        fn isLowPriorityHandler(_: *Socket) LowPriorityState {
            return .none;
        }

        pub fn internalLinkLoop(ctx: *Self, loop: *Loop) void {
            ctx.next = loop.data.head;
            ctx.prev = null;
            if (loop.data.head) |head| head.prev = ctx;
            loop.data.head = ctx;
        }
    };

    if (build_opts.ssl_lib != .nossl and ssl) {
        return struct {
            const Self = @This();
            const SslCallbacks = c.SslCallbacks(Socket);

            sc: BaseContext,
            ssl_ctx: ?*c.SSL_CTX,
            is_parent: bool,
            n_open: *const fn (allocator: Allocator, s: *Self, is_client: bool, ip: []u8) anyerror!*Self,
            on_data: *const fn (allocator: Allocator, s: *Self, data: []u8) anyerror!*Self,
            on_writable: *const fn (allocator: Allocator, s: *Self) anyerror!*Self,
            on_close: *const fn (allocator: Allocator, s: *Self, code: i32, reason: ?*anyopaque) anyerror!*Self,
            on_server_name: ?*const fn (s: *Self, hostname: []const u8) void = null,
            sni: ?*anyopaque, // TODO: probably can explicitly type this
            ext: ?SocketCtxExt = null,

            pub fn init(allocator: Allocator, loop: *Loop, opts: SocketCtxOpts) !*Self {
                // initialize ssl loop data (if none exists)
                try initLoopSslData(allocator, loop);
                const ssl_ctx = try createSslCtxFromOpts(allocator, opts);
                errdefer freeSslCtx(allocator, ssl_ctx);
                if (ssl_ctx == null) return error.FailedSslCtxInit;
                var ctx = try allocator.create(Self);
                errdefer allocator.destroy(ctx);
                ctx.sc = BaseContext.internalInit(loop);
                ctx.ssl_ctx = ssl_ctx;
                ctx.is_parent = true;
                ctx.sc.is_low_priority = @ptrCast(&Self.isLowPriority);
                _ = c.SSL_CTX_set_tlsext_servername_callback(ctx.ssl_ctx, &Self.sniCb);
                _ = c.SSL_CTX_set_tlsext_servername_arg(ctx.ssl_ctx, ctx);
                ctx.sni = try allocator.create(sni.SniNode);
                ctx.sni.?.* = sni.SniNode.init(allocator);
                return ctx;
            }

            fn resolveContext(ctx: *Self, hostname: []const u8) ?*ssl.SSL_CTX {
                var user = sni.sniFind(ctx.sni, hostname);
                if (user) |u| return @ptrCast(@alignCast(u));
                if (ctx.on_server_name) |cb| {
                    cb(ctx, hostname);
                    user = sni.sniFind(ctx.sni, hostname);
                } else return null;
                return @ptrCast(@alignCast(user));
            }

            fn sniCb(ssl_: ?*c.SSL, _: [*c]c_int, arg: ?*anyopaque) callconv(.C) c_int {
                if (ssl_) |s| {
                    const tmp_hostname: [*c]const u8 = ssl.SSL_get_servername(s, ssl.TLSEXT_NAMETYPE_host_name);
                    if (tmp_hostname != null) {
                        const hostname: []const u8 = std.mem.span(tmp_hostname);
                        if (resolveContext(@ptrCast(@alignCast(arg)), hostname)) |resolved_ssl_context| {
                            _ = ssl.SSL_set_SSL_CTX(ssl_, resolved_ssl_context);
                        } else {
                            // TODO: Call a blocking callback notifying of missing context???
                        }
                    }
                    return ssl.SSL_TLSEXT_ERR_OK;
                } else return ssl.SSL_TLSEXT_ERR_NOACK;
            }

            fn freeSslCtx(allocator: Allocator, ssl_ctx: ?*ssl.SSL_CTX) void {
                if (ssl_ctx) |ctx| {
                    // if set, free password string
                    if (ssl.SSL_CTX_get_default_passwd_cb_userdata(ctx)) |pwd| {
                        allocator.free(std.mem.span(@as([*c]u8, @ptrCast(@alignCast(pwd)))));
                    }
                    ssl.SSL_CTX_free(ctx);
                }
            }

            pub fn isLowPriority(self: *Self) LowPriorityState {
                return @enumFromInt(@as(u16, @intCast(c.SSL_in_init(self.ssl))));
            }

            pub fn createSslCtxFromOpts(allocator: Allocator, options: SocketCtxOpts) !?*ssl.SSL_CTX {
                // create ssl context
                const ssl_context: ?*ssl.SSL_CTX = ssl.SSL_CTX_new(ssl.TLS_method());
                // default options (DO NOT CHANGE -- will break shit)
                _ = ssl.SSL_CTX_set_read_ahead(ssl_context, 1);
                _ = ssl.SSL_CTX_set_mode(ssl_context, ssl.SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);

                // require minimum TLS 1.2
                if (ssl.SSL_CTX_set_min_proto_version(ssl_context, ssl.TLS1_2_VERSION) != 1) return error.FailedSslCtxInit;

                // below are helpers; can implement custom shit by using native
                // handle directly
                if (options.ssl_prefer_low_mem_usg) {
                    _ = ssl.SSL_CTX_set_mode(ssl_context, ssl.SSL_MODE_RELEASE_BUFFERS);
                }

                if (options.passphrase) |passphrase| {
                    // when freeing, we need to call `SSL_CTX_get_default_passwd_cb_userdata`
                    // and free if set
                    const p = try allocator.dupeZ(u8, passphrase); // dupe wouldn't copy null terminator
                    ssl.SSL_CTX_set_default_passwd_cb_userdata(ssl_context, p.ptr);
                    ssl.SSL_CTX_set_default_passwd_cb(ssl_context, SslCallbacks.passphraseCb);
                }

                if (options.cert_file_path) |cert_file_path| {
                    if (ssl.SSL_CTX_use_certificate_chain_file(ssl_context, cert_file_path.ptr) != 1) {
                        freeSslCtx(allocator, ssl_context);
                        return error.CertChainFileError;
                    }
                }

                if (options.key_file_path) |key_file_path| {
                    if (ssl.SSL_CTX_use_PrivateKey_file(ssl_context, key_file_path.ptr, ssl.SSL_FILETYPE_PEM) != 1) {
                        freeSslCtx(allocator, ssl_context);
                        return error.PrivateKeyFileError;
                    }
                }

                if (options.ca_file_path) |ca_file_path| {
                    const ca_list: ?*ssl.struct_stack_st_X509_NAME = ssl.SSL_load_client_CA_file(ca_file_path.ptr);
                    if (ca_list == null) {
                        freeSslCtx(allocator, ssl_context);
                        return error.CaFileError;
                    }
                    ssl.SSL_CTX_set_client_CA_list(ssl_context, ca_list);
                    if (ssl.SSL_CTX_load_verify_locations(ssl_context, ca_file_path.ptr, null) != 1) {
                        freeSslCtx(allocator, ssl_context);
                        return error.CaFileError;
                    }
                    ssl.SSL_CTX_set_verify(ssl_context, ssl.SSL_VERIFY_PEER, null);
                }

                if (options.dh_params_file_path) |dh_params_file_path| {
                    var dh_2048: ?*ssl.DH = null;
                    if (std.c.fopen(dh_params_file_path.ptr, "r")) |dh_file| {
                        defer _ = std.c.fclose(dh_file);
                        dh_2048 = ssl.PEM_read_DHparams(@ptrCast(@alignCast(dh_file)), null, null, null);
                    } else {
                        freeSslCtx(allocator, ssl_context);
                        return error.DhParamsFileError;
                    }
                    if (dh_2048 == null) {
                        freeSslCtx(allocator, ssl_context);
                        return error.DhParamsFileError;
                    }
                    const set_tmp_dh = ssl.SSL_CTX_set_tmp_dh(ssl_context, dh_2048);
                    ssl.DH_free(dh_2048);
                    if (set_tmp_dh != 1) {
                        freeSslCtx(allocator, ssl_context);
                        return error.DhParamsFileError;
                    }

                    // OWASP Cipher String 'A+' (https://www.owasp.org/index.php/TLS_Cipher_String_Cheat_Sheet)
                    const cipher = "DHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256";
                    if (ssl.SSL_CTX_set_cipher_list(ssl_context, cipher) != 1) {
                        freeSslCtx(allocator, ssl_context);
                        return error.SetCipherListError;
                    }
                }

                if (options.ssl_ciphers) |ssl_ciphers| {
                    if (ssl.SSL_CTX_set_cipher_list(ssl_context, ssl_ciphers.ptr) != 1) {
                        freeSslCtx(allocator, ssl_context);
                        return error.SetCipherListError;
                    }
                }

                // must free this via `freeSslCtx`
                return ssl_context;
            }

            /// User should not call this function directly.
            fn initLoopSslData(allocator: Allocator, loop: *Loop) !void {
                if (loop.data.ssl_data == null) {
                    const loop_ssl_data = try allocator.create(c.LoopSslData(Socket));
                    errdefer allocator.destroy(loop_ssl_data);
                    const ssl_read_output = try allocator.alloc(u8, RECV_BUFFER_LENGTH + RECV_BUFFER_PADDING * 2);
                    errdefer allocator.free(ssl_read_output);
                    if (c.OPENSSL_init_ssl(0, null) != 1) return error.FailedSslInit;
                    loop_ssl_data.* = .{
                        .ssl_read_output = ssl_read_output,
                        .shared_biom = c.BIO_meth_new(ssl.BIO_TYPE_MEM, "zS BIO"),
                    };
                    if (c.BIO_meth_set_create(loop_ssl_data.shared_biom, SslCallbacks.bioCreate) == 1) return error.FailedSslBioMethCreate;
                    if (c.BIO_meth_set_write(loop_ssl_data.shared_biom, SslCallbacks.bioWrite) == -1) return error.FailedSslBioMethWrite;
                }
            }

            pub fn getExt(self: *const Self) *?SocketCtxExt {
                return &self.ext;
            }

            pub fn getLoop(self: *Self, _: bool) *Loop {
                return self.sc.loop;
            }

            pub fn setOnOpen(
                self: *Self,
                ssl_on_open: *const fn (allocator: Allocator, s: *Socket, is_client: bool, ip: []u8) anyerror!*Socket,
            ) void {
                self.sc.on_open = @ptrCast(ssl_on_open);
                self.on_open = ssl_on_open;
            }

            pub fn setOnData(
                self: *Self,
                ssl_on_data: *const fn (allocator: Allocator, s: *Socket, data: []u8) anyerror!*Socket,
            ) void {
                self.sc.on_data = @ptrCast(ssl_on_data);
                self.on_data = ssl_on_data;
            }

            pub fn setOnWritable(
                self: *Self,
                ssl_on_writable: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            ) void {
                self.sc.on_writable = @ptrCast(ssl_on_writable);
                self.on_writable = ssl_on_writable;
            }

            pub fn setOnClose(
                self: *Self,
                ssl_on_close: *const fn (allocator: Allocator, s: *Socket, code: i32, reason: ?*anyopaque) anyerror!*Socket,
            ) void {
                self.sc.on_close = @ptrCast(ssl_on_close);
                self.on_close = ssl_on_close;
            }

            pub fn setOnTimeout(
                self: *Self,
                ssl_on_timeout: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            ) void {
                self.sc.on_socket_timeout = @ptrCast(ssl_on_timeout);
            }

            pub fn setOnEnd(
                self: *Self,
                ssl_on_end: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            ) void {
                self.sc.on_end = @ptrCast(ssl_on_end);
            }

            pub fn connect(self: *Self, allocator: Allocator, accepted_fd: SocketDescriptor, addr_ip: []u8) !*Self {
                _ = self; // autofix
                _ = allocator; // autofix
                _ = accepted_fd; // autofix
                _ = addr_ip; // autofix
            }

            pub fn listen(self: *Self, allocator: Allocator, host: ?[:0]const u8, port: u64, options: u64) !*Socket.ListenSocket {
                _ = self; // autofix
                _ = allocator; // autofix
                _ = host; // autofix
                _ = port; // autofix
                _ = options; // autofix
                // TODO(cryptodeal): need to implement Pollv2
            }

            pub fn getNativeHandle(self: *Self) ?*c.SSL_CTX {
                return self.ssl_ctx;
            }

            pub fn linkSocket(self: *Self, s: *Socket) void {
                s.context = self;
                s.next = self.head_sockets;
                s.prev = null;
                if (self.head_sockets) |head_sockets| head_sockets.prev = s;
                self.head_sockets = s;
            }

            /// Not intended to be called directly by the user.
            pub fn unlinkSocket(self: *Self, s: *Socket) void {
                if (self.iterator != null) self.iterator = s.next;
                if (s.prev == s.next) {
                    self.head_sockets = null;
                } else {
                    if (s.prev) |prev| {
                        prev.next = s.next;
                    } else {
                        self.head_sockets = s.next;
                    }
                    if (s.next) |next| next.prev = s.prev;
                }
            }
        };
    } else {
        return struct {
            const Self = @This();

            loop: *Loop,
            global_tick: u32 = 0,
            timestamp: u8 = 0,
            long_timestamp: u8 = 0,
            head_sockets: ?*Socket = null,
            head_listen_sockets: ?*Socket = null,
            iterator: ?*Socket = null,
            prev: ?*Self = null,
            next: ?*Self = null,
            on_pre_open: ?*const fn (fd: SocketDescriptor) SocketDescriptor = null,
            on_open: *const fn (allocator: Allocator, s: *Socket, is_client: bool, ip: []u8) anyerror!*Socket,
            on_data: *const fn (allocator: Allocator, s: *Socket, data: []u8) anyerror!*Socket,
            on_writable: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            on_close: *const fn (allocator: Allocator, s: *Socket, code: i32, reason: ?*anyopaque) anyerror!*Socket,
            on_socket_timeout: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            on_socket_long_timeout: ?*const fn (allocator: Allocator, s: *Socket) anyerror!*Socket = null,
            on_connect_error: ?*const fn (s: *Socket, code: i32) anyerror!*Socket = null,
            on_end: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            is_low_prio: *const fn (s: *Socket) LowPriorityState = &isLowPriorityHandler,
            ext: ?SocketCtxExt = null,

            pub fn init(allocator: Allocator, loop: *Loop) !*Self {
                const self = try allocator.create(Self);
                self.* = .{
                    .loop = loop,
                    .on_open = undefined,
                    .on_data = undefined,
                    .on_writable = undefined,
                    .on_close = undefined,
                    .on_socket_timeout = undefined,
                    .on_end = undefined,
                };
                self.internalLinkLoop(loop);
                return self;
            }

            // User should not call this function directly.
            pub fn internalInit(loop: *Loop) Self {
                var self: Self = .{
                    .loop = loop,
                };
                self.internalLinkLoop(loop);
                return self;
            }

            fn isLowPriorityHandler(_: *Socket) LowPriorityState {
                return .none;
            }

            pub fn internalLinkLoop(ctx: *Self, loop: *Loop) void {
                ctx.next = loop.data.head;
                ctx.prev = null;
                if (loop.data.head) |head| head.prev = ctx;
                loop.data.head = ctx;
            }

            pub fn getExt(self: *const Self) *?SocketCtxExt {
                return &self.ext;
            }

            pub fn getLoop(self: *Self, _: bool) *Loop {
                return self.loop;
            }

            pub fn setOnOpen(
                self: *Self,
                on_open: *const fn (allocator: Allocator, s: *Socket, is_client: bool, ip: []u8) anyerror!*Socket,
            ) void {
                self.on_open = on_open;
            }

            pub fn setOnData(
                self: *Self,
                on_data: *const fn (allocator: Allocator, s: *Socket, data: []u8) anyerror!*Socket,
            ) void {
                self.on_data = on_data;
            }

            pub fn setOnWritable(
                self: *Self,
                on_writable: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            ) void {
                self.on_writable = on_writable;
            }

            pub fn setOnClose(
                self: *Self,
                on_close: *const fn (allocator: Allocator, s: *Socket, code: i32, reason: ?*anyopaque) anyerror!*Socket,
            ) void {
                self.on_close = on_close;
            }

            pub fn setOnTimeout(
                self: *Self,
                on_timeout: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            ) void {
                self.on_socket_timeout = on_timeout;
            }

            pub fn setOnEnd(
                self: *Self,
                on_end: *const fn (allocator: Allocator, s: *Socket) anyerror!*Socket,
            ) void {
                self.on_end = on_end;
            }

            pub fn listen(self: *Self, allocator: Allocator, host: ?[:0]const u8, port: u64, options: u64) !*Socket.ListenSocket {
                const listen_socket_fd = try bsd.createListenSocket(host, port, options);
                var p = try PollT(Socket.ListenSocket, Loop).init(allocator, self.loop, false, listen_socket_fd, .semi_socket);
                try p.start(self.loop, SOCKET_READABLE);
                // TODO: might need to add a means to init the extension
                p.ext = .{
                    .s = .{
                        .p = undefined,
                        .context = self,
                        .timeout = 255,
                        .long_timeout = 255,
                        .low_prio_state = .none,
                        .prev = null,
                        .next = null,
                        .ext = null,
                    },
                };
                self.linkListenSocket(&p.ext.?);
                return &p.ext.?;
            }

            pub fn linkSocket(self: *Self, s: *Socket) void {
                s.context = self;
                s.next = self.head_sockets;
                s.prev = null;
                if (self.head_sockets) |head_sockets| head_sockets.prev = s;
                self.head_sockets = s;
            }

            /// Not intended to be called directly by the user.
            pub fn unlinkSocket(self: *Self, s: *Socket) void {
                if (self.iterator != null) self.iterator = s.next;
                if (s.prev == s.next) {
                    self.head_sockets = null;
                } else {
                    if (s.prev) |prev| {
                        prev.next = s.next;
                    } else {
                        self.head_sockets = s.next;
                    }
                    if (s.next) |next| next.prev = s.prev;
                }
            }

            fn linkListenSocket(self: *Self, ls: *Socket.ListenSocket) void {
                if (self.iterator != null and ls == @as(*Socket.ListenSocket, @ptrCast(@alignCast(self.iterator)))) {
                    self.iterator = ls.s.next;
                }
                if (ls.s.prev == ls.s.next) {
                    self.head_listen_sockets = null;
                } else {
                    if (ls.s.prev) |prev| {
                        prev.next = ls.s.next;
                    } else {
                        self.head_listen_sockets = @ptrCast(@alignCast(ls.s.next));
                    }
                    if (ls.s.next) |next| next.prev = ls.s.prev;
                }
            }
        };
    }
}
