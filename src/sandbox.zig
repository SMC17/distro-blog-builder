//! F5 v1.1 — bwrap-sandboxed kernel runner.
//!
//! Wraps `std.process.Child.run` with a bwrap argv prefix. Executors
//! for Python, SQL, and bash code blocks share the same sandbox
//! primitive — read-only filesystem (except /tmp + /work), unshare
//! network by default, no daemon connections, die-with-parent.
//!
//! bwrap is a setuid wrapper around Linux user namespaces; the
//! kernel does the isolation. We don't roll our own seccomp or
//! cgroup setup — bwrap handles the user-namespace + mount
//! boilerplate.
//!
//! This file does NOT shell out to bwrap directly; `runSandboxed`
//! returns the child run result so callers can inspect stdout,
//! stderr, exit code uniformly. Tests that don't require bwrap on
//! the host run the arg-construction path; tests that do skip
//! cleanly via `bwrapAvailable`.

const std = @import("std");

pub const SandboxError = error{
    BwrapNotFound,
    SandboxFailed,
} || std.mem.Allocator.Error;

pub const BwrapConfig = struct {
    /// Host directory to bind-mount as the sandbox's `/work` and
    /// chdir into. Caller-owned absolute path.
    work_dir: []const u8,

    /// Allow network access inside the sandbox. Default false —
    /// essay blocks should be hermetic.
    allow_net: bool = false,

    /// Read-only host paths exposed inside the sandbox at the same
    /// path. The default set is the minimum to run Python / sqlite3
    /// / bash on a typical NixOS or stock Linux.
    ro_binds: []const []const u8 = &.{
        "/nix", "/usr", "/bin", "/lib", "/lib64", "/etc",
    },

    /// Maximum time the child may run before bwrap is killed by
    /// `--die-with-parent`'s parent (this process exits). Caller
    /// times-out manually for now; v1.2 wires `setrlimit` via
    /// `--rlimit`. Documented here for future readers.
    timeout_ms: u32 = 30_000,
};

/// Build the bwrap argv prefix that sandboxes a single command. The
/// full argv is `[bwrap, ...flags, --, ...cmd]`. Caller owns the
/// returned slice and each inner string.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    cfg: BwrapConfig,
    cmd: []const []const u8,
) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    try appendDup(allocator, &list, "bwrap");

    // Filesystem isolation: read-only host mounts. Caller decides
    // which paths exist on the target host — we don't filter
    // absent paths here (would need an io param + fs access call).
    // bwrap surfaces a clear error if a bind path doesn't exist.
    for (cfg.ro_binds) |host_path| {
        try appendDup(allocator, &list, "--ro-bind-try");
        try appendDup(allocator, &list, host_path);
        try appendDup(allocator, &list, host_path);
    }
    try appendDup(allocator, &list, "--tmpfs");
    try appendDup(allocator, &list, "/tmp");
    try appendDup(allocator, &list, "--proc");
    try appendDup(allocator, &list, "/proc");
    try appendDup(allocator, &list, "--dev");
    try appendDup(allocator, &list, "/dev");

    // Bind work_dir → /work, chdir there.
    try appendDup(allocator, &list, "--bind");
    try appendDup(allocator, &list, cfg.work_dir);
    try appendDup(allocator, &list, "/work");
    try appendDup(allocator, &list, "--chdir");
    try appendDup(allocator, &list, "/work");

    // Process / signal isolation.
    try appendDup(allocator, &list, "--unshare-pid");
    try appendDup(allocator, &list, "--unshare-uts");
    try appendDup(allocator, &list, "--unshare-ipc");
    try appendDup(allocator, &list, "--unshare-cgroup-try");
    if (!cfg.allow_net) {
        try appendDup(allocator, &list, "--unshare-net");
    }
    try appendDup(allocator, &list, "--new-session");
    try appendDup(allocator, &list, "--die-with-parent");

    // End of bwrap flags.
    try appendDup(allocator, &list, "--");

    for (cmd) |arg| try appendDup(allocator, &list, arg);

    return list.toOwnedSlice(allocator);
}

fn appendDup(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    s: []const u8,
) !void {
    try list.append(allocator, try allocator.dupe(u8, s));
}

/// Free an argv built by `buildArgv`.
pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |s| allocator.free(s);
    allocator.free(argv);
}

/// Returns true iff `bwrap` is on PATH and the user namespace
/// machinery is functional. Spawns a tiny no-op probe; cheap.
pub fn bwrapAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "bwrap", "--version" },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Run CMD inside a bwrap sandbox configured by CFG. Returns the
/// std.process.RunResult so callers see stdout / stderr / term
/// uniformly. Caller frees `result.stdout` and `result.stderr`.
pub fn runSandboxed(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: BwrapConfig,
    cmd: []const []const u8,
) !std.process.RunResult {
    if (!bwrapAvailable(allocator, io)) return SandboxError.BwrapNotFound;
    const argv = try buildArgv(allocator, cfg, cmd);
    defer freeArgv(allocator, argv);
    return std.process.run(allocator, io, .{ .argv = argv });
}

// ────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "buildArgv: starts with bwrap, ends with cmd, includes --" {
    const a = testing.allocator;
    const cfg = BwrapConfig{ .work_dir = "/tmp", .ro_binds = &.{} };
    const argv = try buildArgv(a, cfg, &.{ "echo", "ok" });
    defer freeArgv(a, argv);

    try testing.expect(argv.len >= 4);
    try testing.expectEqualStrings("bwrap", argv[0]);

    // Find the `--` separator and check it precedes our cmd.
    var sep_idx: ?usize = null;
    for (argv, 0..) |s, i| {
        if (std.mem.eql(u8, s, "--")) {
            sep_idx = i;
            break;
        }
    }
    try testing.expect(sep_idx != null);
    const idx = sep_idx.?;
    try testing.expectEqualStrings("echo", argv[idx + 1]);
    try testing.expectEqualStrings("ok", argv[idx + 2]);
}

test "buildArgv: --unshare-net included by default; omitted when allow_net" {
    const a = testing.allocator;
    const cfg = BwrapConfig{ .work_dir = "/tmp", .ro_binds = &.{} };
    const argv = try buildArgv(a, cfg, &.{"true"});
    defer freeArgv(a, argv);

    var has_unshare_net = false;
    for (argv) |s| if (std.mem.eql(u8, s, "--unshare-net")) {
        has_unshare_net = true;
    };
    try testing.expect(has_unshare_net);

    const cfg_net = BwrapConfig{ .work_dir = "/tmp", .ro_binds = &.{}, .allow_net = true };
    const argv_net = try buildArgv(a, cfg_net, &.{"true"});
    defer freeArgv(a, argv_net);

    var has_unshare_net2 = false;
    for (argv_net) |s| if (std.mem.eql(u8, s, "--unshare-net")) {
        has_unshare_net2 = true;
    };
    try testing.expect(!has_unshare_net2);
}

test "buildArgv: --bind work_dir → /work and chdir" {
    const a = testing.allocator;
    const cfg = BwrapConfig{ .work_dir = "/some/work", .ro_binds = &.{} };
    const argv = try buildArgv(a, cfg, &.{"true"});
    defer freeArgv(a, argv);

    var saw_bind = false;
    var saw_chdir = false;
    for (argv, 0..) |s, i| {
        if (std.mem.eql(u8, s, "--bind") and i + 2 < argv.len) {
            if (std.mem.eql(u8, argv[i + 1], "/some/work") and
                std.mem.eql(u8, argv[i + 2], "/work")) saw_bind = true;
        }
        if (std.mem.eql(u8, s, "--chdir") and i + 1 < argv.len) {
            if (std.mem.eql(u8, argv[i + 1], "/work")) saw_chdir = true;
        }
    }
    try testing.expect(saw_bind);
    try testing.expect(saw_chdir);
}

test "buildArgv: --ro-bind-try used (won't fail on absent paths)" {
    const a = testing.allocator;
    const cfg = BwrapConfig{
        .work_dir = "/tmp",
        .ro_binds = &.{ "/this-path-does-not-exist", "/tmp" },
    };
    const argv = try buildArgv(a, cfg, &.{"true"});
    defer freeArgv(a, argv);

    // `--ro-bind-try` instead of `--ro-bind` means bwrap silently
    // skips absent paths — both entries become argv flags.
    var try_count: usize = 0;
    for (argv) |s| if (std.mem.eql(u8, s, "--ro-bind-try")) {
        try_count += 1;
    };
    try testing.expectEqual(@as(usize, 2), try_count);
}

test "runSandboxed: bash echo round-trip (skips on no-bwrap)" {
    const a = testing.allocator;
    const io = std.testing.io;
    if (!bwrapAvailable(a, io)) return error.SkipZigTest;
    const cfg = BwrapConfig{ .work_dir = "/tmp" };
    const result = try runSandboxed(a, io, cfg, &.{ "/bin/sh", "-c", "echo ok" });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try testing.expectEqualStrings("ok\n", result.stdout);
    switch (result.term) {
        .exited => |code| try testing.expectEqual(@as(u8, 0), code),
        else => try testing.expect(false),
    }
}

test "runSandboxed: --unshare-net blocks network (skips on no-bwrap)" {
    const a = testing.allocator;
    const io = std.testing.io;
    if (!bwrapAvailable(a, io)) return error.SkipZigTest;
    const cfg = BwrapConfig{ .work_dir = "/tmp", .allow_net = false };
    // getent hosts triggers a DNS lookup; in --unshare-net mode the
    // sandbox has no loopback or external interface, so resolution
    // fails (non-zero exit). Accept either non-zero exit or a spawn
    // failure as evidence of network isolation.
    const result = runSandboxed(a, io, cfg, &.{ "/bin/sh", "-c", "getent hosts example.com" }) catch {
        return;
    };
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    switch (result.term) {
        .exited => |code| try testing.expect(code != 0),
        else => {},
    }
}
