const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/dh.h");
});

// TODO(cryptodeal): remove, but makes it easy to browse cimport files
pub usingnamespace c;

pub const Bio = c.BIO;
pub const BioMethod = c.BIO_METHOD;
