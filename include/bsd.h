#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
/* For socklen_t */
#include <sys/socket.h>
#include <netinet/in.h>
#include <fcntl.h>
#endif


struct bsd_addr_t {
    struct sockaddr_storage mem;
    socklen_t len;
    char *ip;
    int ip_length;
    int port;
};
