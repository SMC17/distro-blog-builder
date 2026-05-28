//! F5 / Layer 4 v0 — fenced-block option parser for the sovereign
//! notebook surface.
//!
//! Per `~/Work/lab/blog-builder/docs/notebook-design.md` §2,
//! fenced code blocks in a notebook-mode markdown file gain a
//! metadata header after the language tag:
//!
//!     ```zig run capture=stdout cache=true timeout=30s
//!     const std = @import("std");
//!     pub fn main() !void { ... }
//!     ```
//!
//! This module parses the bit between the leading triple-backticks
//! and the newline (i.e. `zig run capture=stdout cache=true
//! timeout=30s`) into a typed `BlockOptions` struct.
//!
//! Grammar:
//!   tagline    := language ( WS option )*
//!   language   := identifier ; e.g. zig, python, sql, bash
//!   option     := flag | key '=' value
//!   flag       := identifier ; e.g. `run`
//!   key        := identifier
//!   value      := identifier_or_quoted | comma_list
//!
//! Recognized keys (per design): run (flag), capture, cache, timeout,
//! id, depends. Unknown keys surface as `error.InvalidOption` —
//! never silently ignored, never silently retained.

const std = @import("std");

pub const Capture = enum {
    none,
    stdout,
    stdout_stderr,
};

pub const ParseError = error{
    InvalidOption,
    InvalidCapture,
    InvalidTimeout,
    InvalidCache,
    EmptyTagline,
    OutOfMemory,
};

pub const BlockOptions = struct {
    /// Language tag — `zig`, `python`, `sql`, `bash`, etc.
    /// Always present; empty taglines fail with `EmptyTagline`.
    language: []const u8,

    /// Execute the block. Default false (display-only) so a
    /// notebook-mode build is opt-in per block.
    run: bool = false,

    /// What to capture from the kernel's output streams.
    capture: Capture = .stdout,

    /// Whether to memoize via the content-addressed cache. Default
    /// true so re-renders are cheap by default.
    cache: bool = true,

    /// Wall-clock cap in milliseconds. Default 30s per design.
    timeout_ms: u32 = 30_000,

    /// Optional stable id for cross-block reference + cache stability
    /// across whitespace-only edits.
    id: ?[]const u8 = null,

    /// Pseudo-dependency edges — block ids whose hashes participate
    /// in this block's cache key.
    depends: []const []const u8 = &.{},

    /// Whether to render as a Vega-Lite chart. Default false.
    vega: bool = false,

    pub fn deinit(self: *BlockOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.language);
        if (self.id) |id| allocator.free(id);
        for (self.depends) |d| allocator.free(d);
        if (self.depends.len > 0) allocator.free(self.depends);
    }
};

/// Parse the option string between the triple-backticks and the
/// newline. Allocates the language string, optional id, and
/// `depends` entries through `allocator`. Caller must call
/// `BlockOptions.deinit(allocator)`.
pub fn parse(allocator: std.mem.Allocator, tagline: []const u8) ParseError!BlockOptions {
    const trimmed = std.mem.trim(u8, tagline, " \t\r");
    if (trimmed.len == 0) return error.EmptyTagline;

    var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');

    const lang_tok = tokens.next() orelse return error.EmptyTagline;
    const lang = try allocator.dupe(u8, lang_tok);
    errdefer allocator.free(lang);

    var opts = BlockOptions{ .language = lang };
    var depends_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (depends_list.items) |d| allocator.free(d);
        depends_list.deinit(allocator);
    }

    while (tokens.next()) |tok| {
        if (tok.len == 0) continue;

        if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            const key = tok[0..eq];
            const val = tok[eq + 1 ..];
            try applyKeyValue(allocator, &opts, &depends_list, key, val);
        } else {
            // Bare flag (currently only `run`).
            try applyFlag(&opts, tok);
        }
    }

    opts.depends = try depends_list.toOwnedSlice(allocator);
    return opts;
}

fn applyFlag(opts: *BlockOptions, flag: []const u8) ParseError!void {
    if (std.mem.eql(u8, flag, "run")) {
        opts.run = true;
    } else if (std.mem.eql(u8, flag, "vega")) {
        opts.vega = true;
    } else {
        return error.InvalidOption;
    }
}

fn applyKeyValue(
    allocator: std.mem.Allocator,
    opts: *BlockOptions,
    depends_list: *std.ArrayList([]const u8),
    key: []const u8,
    val: []const u8,
) ParseError!void {
    if (std.mem.eql(u8, key, "capture")) {
        opts.capture = parseCapture(val) catch return error.InvalidCapture;
    } else if (std.mem.eql(u8, key, "cache")) {
        opts.cache = parseBool(val) catch return error.InvalidCache;
    } else if (std.mem.eql(u8, key, "timeout")) {
        opts.timeout_ms = parseTimeout(val) catch return error.InvalidTimeout;
    } else if (std.mem.eql(u8, key, "id")) {
        if (val.len == 0) return error.InvalidOption;
        opts.id = try allocator.dupe(u8, val);
    } else if (std.mem.eql(u8, key, "depends")) {
        var deps = std.mem.tokenizeScalar(u8, val, ',');
        while (deps.next()) |dep| {
            const trimmed_dep = std.mem.trim(u8, dep, " \t");
            if (trimmed_dep.len == 0) continue;
            const owned = try allocator.dupe(u8, trimmed_dep);
            try depends_list.append(allocator, owned);
        }
    } else if (std.mem.eql(u8, key, "vega")) {
        opts.vega = parseBool(val) catch return error.InvalidOption;
    } else if (std.mem.eql(u8, key, "run")) {
        // `run=true` / `run=false` — also accept the keyed form.
        opts.run = parseBool(val) catch return error.InvalidOption;
    } else {
        return error.InvalidOption;
    }
}

fn parseCapture(val: []const u8) !Capture {
    if (std.mem.eql(u8, val, "stdout")) return .stdout;
    if (std.mem.eql(u8, val, "stdout+stderr")) return .stdout_stderr;
    if (std.mem.eql(u8, val, "none")) return .none;
    return error.InvalidCapture;
}

fn parseBool(val: []const u8) !bool {
    if (std.mem.eql(u8, val, "true")) return true;
    if (std.mem.eql(u8, val, "false")) return false;
    return error.InvalidBool;
}

/// Parse `30s`, `500ms`, `2m` into milliseconds.
fn parseTimeout(val: []const u8) !u32 {
    if (val.len == 0) return error.InvalidTimeout;

    // Find where the digits end.
    var i: usize = 0;
    while (i < val.len and val[i] >= '0' and val[i] <= '9') : (i += 1) {}
    if (i == 0) return error.InvalidTimeout;

    const num_str = val[0..i];
    const unit = val[i..];

    const num = std.fmt.parseInt(u32, num_str, 10) catch return error.InvalidTimeout;

    if (unit.len == 0 or std.mem.eql(u8, unit, "ms")) return num;
    if (std.mem.eql(u8, unit, "s")) return std.math.mul(u32, num, 1000) catch error.InvalidTimeout;
    if (std.mem.eql(u8, unit, "m")) return std.math.mul(u32, num, 60_000) catch error.InvalidTimeout;
    return error.InvalidTimeout;
}

// ────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parse: language only — display-only block" {
    const a = testing.allocator;
    var opts = try parse(a, "zig");
    defer opts.deinit(a);

    try testing.expectEqualStrings("zig", opts.language);
    try testing.expectEqual(false, opts.run);
    try testing.expectEqual(Capture.stdout, opts.capture);
    try testing.expectEqual(true, opts.cache);
    try testing.expectEqual(@as(u32, 30_000), opts.timeout_ms);
    try testing.expectEqual(@as(?[]const u8, null), opts.id);
    try testing.expectEqual(@as(usize, 0), opts.depends.len);
}

test "parse: bare run flag enables execution" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run");
    defer opts.deinit(a);
    try testing.expectEqual(true, opts.run);
}

test "parse: capture=stdout+stderr" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run capture=stdout+stderr");
    defer opts.deinit(a);
    try testing.expectEqual(Capture.stdout_stderr, opts.capture);
}

test "parse: capture=none" {
    const a = testing.allocator;
    var opts = try parse(a, "bash run capture=none");
    defer opts.deinit(a);
    try testing.expectEqual(Capture.none, opts.capture);
}

test "parse: cache=false disables memoization" {
    const a = testing.allocator;
    var opts = try parse(a, "python run cache=false");
    defer opts.deinit(a);
    try testing.expectEqual(false, opts.cache);
}

test "parse: timeout in seconds" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run timeout=10s");
    defer opts.deinit(a);
    try testing.expectEqual(@as(u32, 10_000), opts.timeout_ms);
}

test "parse: timeout in milliseconds" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run timeout=500ms");
    defer opts.deinit(a);
    try testing.expectEqual(@as(u32, 500), opts.timeout_ms);
}

test "parse: timeout in minutes" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run timeout=2m");
    defer opts.deinit(a);
    try testing.expectEqual(@as(u32, 120_000), opts.timeout_ms);
}

test "parse: id assigned" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run id=blockA");
    defer opts.deinit(a);
    try testing.expectEqualStrings("blockA", opts.id.?);
}

test "parse: depends comma-separated list" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run depends=alpha,beta,gamma");
    defer opts.deinit(a);
    try testing.expectEqual(@as(usize, 3), opts.depends.len);
    try testing.expectEqualStrings("alpha", opts.depends[0]);
    try testing.expectEqualStrings("beta", opts.depends[1]);
    try testing.expectEqualStrings("gamma", opts.depends[2]);
}

test "parse: full design-doc example" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run capture=stdout cache=true timeout=30s id=blockA depends=blockB,blockC");
    defer opts.deinit(a);
    try testing.expectEqualStrings("zig", opts.language);
    try testing.expectEqual(true, opts.run);
    try testing.expectEqual(Capture.stdout, opts.capture);
    try testing.expectEqual(true, opts.cache);
    try testing.expectEqual(@as(u32, 30_000), opts.timeout_ms);
    try testing.expectEqualStrings("blockA", opts.id.?);
    try testing.expectEqual(@as(usize, 2), opts.depends.len);
}

test "parse: empty tagline fails loud" {
    const a = testing.allocator;
    const result = parse(a, "");
    try testing.expectError(error.EmptyTagline, result);
}

test "parse: whitespace-only tagline fails loud" {
    const a = testing.allocator;
    const result = parse(a, "   \t  ");
    try testing.expectError(error.EmptyTagline, result);
}

test "parse: unknown option key fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig run frobnicate=42");
    try testing.expectError(error.InvalidOption, result);
}

test "parse: unknown bare flag fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig sneakyflag");
    try testing.expectError(error.InvalidOption, result);
}

test "parse: invalid capture value fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig run capture=stderr");
    try testing.expectError(error.InvalidCapture, result);
}

test "parse: invalid timeout fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig run timeout=abc");
    try testing.expectError(error.InvalidTimeout, result);
}

test "parse: invalid timeout unit fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig run timeout=10h");
    try testing.expectError(error.InvalidTimeout, result);
}

test "parse: invalid cache value fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig run cache=maybe");
    try testing.expectError(error.InvalidCache, result);
}

test "parse: empty id fails loud" {
    const a = testing.allocator;
    const result = parse(a, "zig run id=");
    try testing.expectError(error.InvalidOption, result);
}

test "parse: run=true keyed form" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run=true");
    defer opts.deinit(a);
    try testing.expectEqual(true, opts.run);
}

test "parse: run=false keyed form" {
    const a = testing.allocator;
    var opts = try parse(a, "zig run=false");
    defer opts.deinit(a);
    try testing.expectEqual(false, opts.run);
}

test "parse: leading/trailing whitespace tolerated" {
    const a = testing.allocator;
    var opts = try parse(a, "  zig run  ");
    defer opts.deinit(a);
    try testing.expectEqualStrings("zig", opts.language);
    try testing.expectEqual(true, opts.run);
}
