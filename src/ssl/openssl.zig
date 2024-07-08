pub const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/dh.h");
});

pub const Bio = c.BIO;
pub const bioGetData = c.BIO_get_data;
pub const bioSetFlags = c.BIO_set_flags;
pub const BioMethod = c.BIO_METHOD;
pub const bioSetInit = c.BIO_set_init;
pub const Ssl = c.SSL;
pub const SslCtx = c.SSL_CTX;
