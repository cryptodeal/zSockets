pub const c = @cImport({
    @cDefine("struct_XSTAT", ""); // fix error
    @cDefine("OPENSSL_EXTRA", "");
    @cInclude("wolfssl/options.h");
    @cInclude("wolfssl/openssl/ssl.h");
    @cInclude("wolfssl/openssl/bio.h");
    @cInclude("wolfssl/openssl/err.h");
    @cInclude("wolfssl/openssl/dh.h");
});

pub const Bio = c.WOLFSSL_BIO;
pub const bioGetData = c.wolfSSL_BIO_get_data;
pub const BioMethod = c.WOLFSSL_BIO_METHOD;
pub const bioSetFlags = c.wolfSSL_BIO_set_flags;
pub const bioSetInit = c.wolfSSL_BIO_set_init;
pub const Ssl = c.WOLFSSL;
pub const SslCtx = c.WOLFSSL_CTX;
