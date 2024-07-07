const c = @cImport({
    @cDefine("struct_XSTAT", ""); // fix error
    @cInclude("wolfssl/wolfcrypt/settings.h");
    @cInclude("wolfssl/openssl/ssl.h");
    @cInclude("wolfssl/openssl/bio.h");
    @cInclude("wolfssl/openssl/err.h");
    @cInclude("wolfssl/openssl/dh.h");
});

// TODO(cryptodeal): remove, but makes it easy to browse cimport files
pub usingnamespace c;

pub const Bio = c.WOLFSSL_BIO;

pub const BioMethod = c.WOLFSSL_BIO_METHOD;
