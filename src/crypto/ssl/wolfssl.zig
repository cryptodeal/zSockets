pub usingnamespace @cImport({
    @cDefine("struct_XSTAT", ""); // fix error
    @cDefine("OPENSSL_EXTRA", "");
    @cInclude("wolfssl/options.h");
    @cInclude("wolfssl/openssl/ssl.h");
    @cInclude("wolfssl/openssl/bio.h");
    @cInclude("wolfssl/openssl/err.h");
    @cInclude("wolfssl/openssl/dh.h");
});
