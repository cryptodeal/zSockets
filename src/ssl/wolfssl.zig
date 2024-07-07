const wolfssl = @cImport({
    @cInclude("wolfssl/options.h");
    @cInclude("wolfssl/openssl/ssl.h");
    @cInclude("wolfssl/openssl/bio.h");
    @cInclude("wolfssl/openssl/err.h");
    @cInclude("wolfssl/openssl/dh.h");
});

pub usingnamespace wolfssl;
