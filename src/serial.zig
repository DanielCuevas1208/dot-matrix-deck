// Serial output helpers for headless verification.
//
// Public test ROMs report results through the link port. The helpers
// extract lines and produce a pass/fail verdict from the raw bytes.

const std = @import("std");

pub const Verdict = enum {
    pending,
    pass,
    fail,
    inconclusive,
};

pub fn hasToken(haystack: []const u8, token: []const u8) bool {
    return std.mem.indexOf(u8, haystack, token) != null;
}

pub fn startsWithToken(haystack: []const u8, token: []const u8) bool {
    if (haystack.len < token.len) return false;
    return std.mem.eql(u8, haystack[0..token.len], token);
}

pub fn countNewlines(bytes: []const u8) usize {
    var count: usize = 0;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

// Collects the printable tail of the serial stream. Test ROMs print one
// final summary line; later writes may add trailing whitespace.
pub fn lastLine(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] == '\n' or bytes[end - 1] == '\r')) : (end -= 1) {}
    var start = end;
    while (start > 0 and bytes[start - 1] != '\n') : (start -= 1) {}
    return bytes[start..end];
}

pub fn printable(bytes: []const u8) []const u8 {
    var end = bytes.len;
    while (end > 0 and (bytes[end - 1] < 0x20 or bytes[end - 1] == 0x7f)) : (end -= 1) {}
    return bytes[0..end];
}

pub fn verdictOf(bytes: []const u8) Verdict {
    if (hasToken(bytes, "Failed")) return .fail;
    if (hasToken(bytes, "FAIL")) return .fail;
    if (hasToken(bytes, "Passed")) return .pass;
    if (hasToken(bytes, "PASS")) return .pass;
    return .pending;
}

pub fn trim(buffer: []const u8) []const u8 {
    return std.mem.trim(u8, buffer, " \t\r\n\x00");
}

test "verdictOf recognises blargg and bundled test output" {
    try std.testing.expectEqual(Verdict.pass, verdictOf("00-special\nPassed\n"));
    try std.testing.expectEqual(Verdict.fail, verdictOf("Failed\n"));
    try std.testing.expectEqual(Verdict.pass, verdictOf("PASS\n"));
    try std.testing.expectEqual(Verdict.fail, verdictOf("FAIL timer\n"));
    try std.testing.expectEqual(Verdict.pending, verdictOf("running..."));
}

test "lastLine and trim" {
    try std.testing.expectEqualStrings("Passed", lastLine("01-special\nPassed\n"));
    try std.testing.expectEqualStrings("PASS", trim("PASS\n\x00"));
    try std.testing.expectEqual(@as(usize, 2), countNewlines("a\nb\n"));
}
