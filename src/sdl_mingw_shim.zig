//! Windows-only shim for the msys2/mingw SDL2 dynamic library.
//!
//! The mingw-w64 SDL2.dll imports `ftello64` and `fseeko64` from the
//! Mingw C runtime. Zig links msvcrt.dll, which exports the 64-bit
//! variants as `_ftelli64` and `_fseeki64`. These exports satisfy the
//! DLL imports so the windowed frontend links and runs.

const FILE = opaque {};

extern fn _ftelli64(stream: *FILE) c_longlong;
extern fn _fseeki64(stream: *FILE, offset: c_longlong, whence: c_int) c_int;

export fn ftello64(stream: *FILE) callconv(.c) c_longlong {
    return _ftelli64(stream);
}

export fn fseeko64(stream: *FILE, offset: c_longlong, whence: c_int) callconv(.c) c_int {
    return _fseeki64(stream, offset, whence);
}
