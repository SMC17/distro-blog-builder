const std = @import("std");
const block_opts = @import("block_opts.zig");
const sandbox = @import("sandbox.zig");

/// Block Executor for Computational Essays.
///
/// v1.2 wires the language-specific kernels (Python, bash) through
/// the bwrap sandbox primitive in `sandbox.zig`. Each kernel runs in
/// a fresh user namespace with read-only host mounts, no network
/// (unless `cfg.allow_net`), and `--die-with-parent` lifetime.
///
/// The legacy `execute(lang, code, opts)` signature stays for
/// renderer compat — it returns `error.NotImplementedYet` until the
/// renderer cascades io through `renderMarkdown`. Callers that have
/// io already (CLI entry points, test code) use the per-language
/// methods directly: `executePython(io, code, opts)`,
/// `executeBash(io, code, opts)`.
pub const Executor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Executor {
        return .{ .allocator = allocator };
    }

    /// Renderer-facing entry point. Routes by language to the
    /// sandboxed per-language kernel. Unsupported languages
    /// (e.g. zig — sandbox compile-then-run is v1.4 work) surface
    /// as `error.UnsupportedLanguage` so the renderer falls back to
    /// display-only.
    pub fn execute(
        self: *Executor,
        io: std.Io,
        lang: []const u8,
        code: []const u8,
        opts: block_opts.BlockOptions,
    ) ![]const u8 {
        if (std.mem.eql(u8, lang, "python")) {
            return self.executePython(io, code, opts);
        }
        if (std.mem.eql(u8, lang, "bash") or std.mem.eql(u8, lang, "sh")) {
            return self.executeBash(io, code, opts);
        }
        return error.UnsupportedLanguage;
    }

    /// Run `python3 -c CODE` inside the bwrap sandbox. Returns
    /// captured stdout owned by the executor's allocator. stderr is
    /// freed; non-zero exit is surfaced as `error.ExecutionFailed`.
    pub fn executePython(
        self: *Executor,
        io: std.Io,
        code: []const u8,
        opts: block_opts.BlockOptions,
    ) ![]u8 {
        _ = opts;
        const cfg = sandbox.BwrapConfig{ .work_dir = "/tmp" };
        return self.runKernel(io, cfg, &.{ "python3", "-c", code });
    }

    /// Run `/bin/sh -c CODE` inside the sandbox.
    pub fn executeBash(
        self: *Executor,
        io: std.Io,
        code: []const u8,
        opts: block_opts.BlockOptions,
    ) ![]u8 {
        _ = opts;
        const cfg = sandbox.BwrapConfig{ .work_dir = "/tmp" };
        return self.runKernel(io, cfg, &.{ "/bin/sh", "-c", code });
    }

    fn runKernel(
        self: *Executor,
        io: std.Io,
        cfg: sandbox.BwrapConfig,
        argv: []const []const u8,
    ) ![]u8 {
        const result = try sandbox.runSandboxed(self.allocator, io, cfg, argv);
        // Free stderr; we surface only stdout. Non-zero exit
        // becomes ExecutionFailed so callers distinguish "kernel
        // ran and produced nothing" from "kernel rejected the code".
        self.allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    self.allocator.free(result.stdout);
                    return error.ExecutionFailed;
                }
            },
            else => {
                self.allocator.free(result.stdout);
                return error.ExecutionFailed;
            },
        }
        return result.stdout;
    }
};

const testing = std.testing;

test "Executor.init compiles cleanly" {
    var executor = Executor.init(testing.allocator);
    _ = &executor;
}

test "execute() routes unsupported language to UnsupportedLanguage" {
    const a = testing.allocator;
    var executor = Executor.init(a);
    const r = executor.execute(testing.io, "haskell", "main = print 1",
        .{ .language = "haskell" });
    try testing.expectError(error.UnsupportedLanguage, r);
}

test "execute() routes bash to executeBash (skips on no-bwrap)" {
    const a = testing.allocator;
    if (!sandbox.bwrapAvailable(a, testing.io)) return error.SkipZigTest;
    var executor = Executor.init(a);
    const out = try executor.execute(testing.io, "bash", "echo via-execute",
        .{ .language = "bash" });
    defer a.free(out);
    try testing.expectEqualStrings("via-execute\n", out);
}

test "executeBash echo round-trip (skips on no-bwrap)" {
    const a = testing.allocator;
    const io = testing.io;
    if (!sandbox.bwrapAvailable(a, io)) return error.SkipZigTest;
    var executor = Executor.init(a);
    const out = try executor.executeBash(io, "echo ok", .{ .language = "bash" });
    defer a.free(out);
    try testing.expectEqualStrings("ok\n", out);
}

test "executeBash surfaces non-zero exit as ExecutionFailed (skips on no-bwrap)" {
    const a = testing.allocator;
    const io = testing.io;
    if (!sandbox.bwrapAvailable(a, io)) return error.SkipZigTest;
    var executor = Executor.init(a);
    const r = executor.executeBash(io, "exit 7", .{ .language = "bash" });
    try testing.expectError(error.ExecutionFailed, r);
}

test "executePython arithmetic round-trip (skips on no-bwrap or no-python3)" {
    const a = testing.allocator;
    const io = testing.io;
    if (!sandbox.bwrapAvailable(a, io)) return error.SkipZigTest;
    // Probe python3 availability inside the sandbox; skip if absent
    // (some minimal hosts ship without python3).
    const probe = sandbox.runSandboxed(a, io, .{ .work_dir = "/tmp" }, &.{
        "/bin/sh", "-c", "command -v python3 >/dev/null 2>&1 && echo y || echo n",
    }) catch return error.SkipZigTest;
    defer a.free(probe.stdout);
    defer a.free(probe.stderr);
    if (!std.mem.startsWith(u8, probe.stdout, "y")) return error.SkipZigTest;

    var executor = Executor.init(a);
    const out = try executor.executePython(io, "print(2 + 3)", .{ .language = "python" });
    defer a.free(out);
    try testing.expectEqualStrings("5\n", out);
}
