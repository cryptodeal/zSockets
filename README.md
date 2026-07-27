# zSockets

## Performant TCP, UDP, TLS, QUIC & HTTP3 Networking

`zSockets` is the [Zig](https://ziglang.org) port of [µSockets](https://github.com/uNetworking/uSockets), which implements a highly optimized non-blocking, thread-per-CPU core networking library. `zSockets` provides a unified API, allowing developers to write code once that targets multiple event backends, platforms, and all supported networking protocols.

## Installation

If you haven't already done so, initialize a zig project:
```sh-session
zig init
```

Install `zSockets` as a dependency to `build.zig.zon`:
```sh-session
zig fetch --save git+https://github.com/cryptodeal/zSockets
```

Add `zSockets` to your `build.zig`:
```zig
exe.root_module.addImport("zSockets", b.dependency("zSockets", .{ .target = target, .optimize = optimize }).module("zSockets"));
```

Import/call into `zSockets` from your codebase:
```zig
const zs = @import("zSockets");
```

## Configuration

When using TCP/UDP (no TLS) and one of the default event backends, the library has zero dependencies and can be compiled to a tiny binary. The following details how to configure to use a specific backend, enable TLS, or support QUIC & HTTP3.

### Event Backends

| Backend | Platforms           | Is Default | Manually Configure |
|---------|---------------------|------------|--------------------|
| epoll   | Linux               | Yes        | -DWITH_EPOLL       |
| kqueue  | Darwin/FreeBSD      | Yes        | -DWITH_KQUEUE      |
| libuv   | supported platforms | No         | -DWITH_LIBUV       |
| GCD     | Darwin              | No         | -DWITH_GCD         |

### TLS

| TLS Library           | Manually Configure |
|-----------------------|--------------------|
| boringssl (preferred) | -DWITH_BORINGSSL   |
| openssl               | -DWITH_OPENSSL     |

### QUIC & HTTP3

| Library | Manually Configure |
|---------|--------------------|
| lsquic  | -DWITH_QUIC        |


## Examples

### Optionally Running With TLS

Clone the repo:
```sh-session
git clone https://github.com/cryptodeal/zSockets.git
```

To run with TLS, generate certs using the `misc/gen_test_certs.sh`
```sh-session
bash misc/gen_test_certs.sh <output path>
```

Modify the examples to point to the relevant certs and call the example using either `-DWITH_BORINGSSL` (preferred) or `-DWITH_OPENSSL`

### Echo Server

```sh-session
zig build echo_server
```

Calls to `localhost:3000` will logged to console.

### Hammer Test Unix

```sh-session
zig build hammer_test_unix
```

### Hammer Test

```sh-session
zig build hammer_test
```

### HTTP Load Test

Run the HTTP Server:
```sh-session
zig build http_server
```

Run the HTTP Load Test (see `examples/http_load_test.zig` for info on customizing options passed):
```sh-session
zig build http_load_test
```

### HTTP3

Run the HTTP3 Server:
```sh-session
zig build http3_server -DWITH_BORINGSSL -DWITH_QUIC
```

Run the HTTP3 Client:
```sh-session
zig build http3_client -DWITH_BORINGSSL -DWITH_QUIC
```

### Peer Verify Test

Ensure that you've generated the relevant TLS certs and that `examples/peer_verify_test.zig` has been modified to point to the correct path for each cert.

Run Peer Verify Test:
```sh-session
zig build peer_verify_test -DWITH_BORINGSSL
```

### TCP Load Test

Run the TCP Server:
```sh-session
zig build tcp_server
```

Run the TCP Load Test (see `examples/tcp_load_test.zig` for info on customizing options passed):
```sh-session
zig build tcp_load_test
```

### UDP Benchmark

Run the UDP Benchmark Server IPv4:
```sh-session
zig build udp_benchmark
```

Run the UDP Benchmark Client IPv4:
```sh-session
zig build udp_benchmark -- --type=client
```

Run the UDP Benchmark Server IPv6:
```sh-session
zig build udp_benchmark -- --protocol=ipv6
```

Run the UDP Benchmark Client IPv6:
```sh-session
zig build udp_benchmark -- --type=client --protocol=ipv6
```

## Roadmap/TODO

- [ ] Unit tests
- [ ] Windows Support
- [ ] `io_uring` backend
- [ ] Improve Quic/HTTP3 implementation