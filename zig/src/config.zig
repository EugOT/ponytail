//! Ponytail config CLI verb — Zig 0.16 (zig-rewrite plan §1.5 Option B).
//!
//! Moves the I/O-bearing parts of hooks/ponytail-config.js + ponytail-fs-safe.js
//! out of process so those JS modules collapse to thin exec wrappers (with a JS
//! fallback). The pure synchronous string helpers (normalize*/isDeactivation*)
//! stay in JS — they are called per-keystroke/per-turn in-process and have no I/O.
//!
//! ponytail: Subcommand + args are passed via ENV (not argv) as an intentional
//! simplification — this dev toolchain (0.16.0-dev.3142) dropped std.os.argv, and
//! the rest of these libc-only binaries already pass parameters by env (see
//! instructions.zig). Ceiling: OS env-size limits and the env visibility of
//! PONYTAIL_CONFIG_VALUE; upgrade path is to move to argv once the toolchain
//! restores std.os.argv. The JS wrappers set these and read one line of stdout:
//!
//!   PONYTAIL_CONFIG_CMD=get-default
//!     → print the resolved default mode (env → config.json → "full"), exit 0.
//!
//!   PONYTAIL_CONFIG_CMD=set-default  PONYTAIL_CONFIG_MODE=<mode>
//!     → validate <mode> as a config mode (off/lite/full/ultra/review); write
//!       {"defaultMode":"<mode>"} to <configDir>/config.json via
//!       common.safeWriteFlag; print the normalized mode; exit 0.
//!       Invalid mode → print nothing, exit 2 (the wrapper treats this as "no
//!       write" and reports failure, same as the JS writeDefaultMode returning null).
//!
//!   PONYTAIL_CONFIG_CMD=write-mode  PONYTAIL_CONFIG_PATH=<path>  PONYTAIL_CONFIG_VALUE=<content>
//!     → common.safeWriteFlag(<path>, <content>) — the symlink-safe flag write
//!       opencode's writeMode needs. Print nothing; exit 0 on success, 1 on refusal.
//!
//! Every write goes through common.safeWriteFlag (symlink-refuse + O_NOFOLLOW
//! atomic write), identical to the JS safeWriteFlag it replaces.

const std = @import("std");
const common = @import("common.zig");

fn env(name: [*:0]const u8) ?[]const u8 {
    const v = common.getenv(name) orelse return null;
    if (v.len == 0) return null;
    return v;
}

fn cmdGetDefault(gpa: std.mem.Allocator) u8 {
    const mode = common.getDefaultMode(gpa) catch return 1;
    defer gpa.free(mode);
    common.writeStdout(mode);
    common.writeStdout("\n");
    return 0;
}

fn cmdSetDefault(gpa: std.mem.Allocator) u8 {
    const raw = env("PONYTAIL_CONFIG_MODE") orelse return 2;
    const normalized = common.normalizeConfigModeAlloc(gpa, raw) orelse return 2;
    defer gpa.free(normalized);

    const path = common.configPath(gpa) catch return 1;
    defer gpa.free(path);

    // config.json sits at a predictable, user-owned path — route the write
    // through the same clobber-resistant writer as the flag (matches the JS
    // writeDefaultMode, which calls safeWriteFlag on the same JSON).
    const json = std.fmt.allocPrint(gpa, "{{\n  \"defaultMode\": \"{s}\"\n}}", .{normalized}) catch return 1;
    defer gpa.free(json);

    // Ensure the parent dir chain exists (configDir may be several levels deep).
    if (std.fs.path.dirname(path)) |d| common.makePathRecursive(gpa, d) catch {};
    common.safeWriteFlag(gpa, path, json) catch return 1;

    common.writeStdout(normalized);
    common.writeStdout("\n");
    return 0;
}

fn cmdWriteMode(gpa: std.mem.Allocator) u8 {
    const path = env("PONYTAIL_CONFIG_PATH") orelse return 2;
    const value = env("PONYTAIL_CONFIG_VALUE") orelse return 2;
    if (std.fs.path.dirname(path)) |d| common.makePathRecursive(gpa, d) catch {};
    common.safeWriteFlag(gpa, path, value) catch return 1;
    return 0;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const cmd = env("PONYTAIL_CONFIG_CMD") orelse {
        // No verb → usage on stderr (via debug.print) and exit 2.
        std.debug.print("ponytail-config: set PONYTAIL_CONFIG_CMD=get-default|set-default|write-mode\n", .{});
        std.process.exit(2);
    };

    const code: u8 = if (std.mem.eql(u8, cmd, "get-default"))
        cmdGetDefault(gpa)
    else if (std.mem.eql(u8, cmd, "set-default"))
        cmdSetDefault(gpa)
    else if (std.mem.eql(u8, cmd, "write-mode"))
        cmdWriteMode(gpa)
    else blk: {
        std.debug.print("ponytail-config: unknown command '{s}'\n", .{cmd});
        break :blk @as(u8, 2);
    };

    if (code != 0) std.process.exit(code);
}

// ── Tests ───────────────────────────────────────────────────────────────────
//
// The verb is thin glue over common.{getDefaultMode,normalizeConfigMode,
// configPath,safeWriteFlag}, all tested in common.zig. The seams owned here are
// the config-mode validation gate and the config.json shape. Use a fixed
// XDG_CONFIG_HOME under a tmp dir so configPath resolves into a writable area.

test "normalizeConfigMode gate: accepts the whitelist, rejects junk" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ "off", "lite", "full", "ultra", "review", "  ULTRA  " }) |m| {
        const r = common.normalizeConfigModeAlloc(gpa, m) orelse return error.TestUnexpectedNull;
        gpa.free(r);
    }
    try std.testing.expect(common.normalizeConfigModeAlloc(gpa, "nope") == null);
    try std.testing.expect(common.normalizeConfigModeAlloc(gpa, "") == null);
}

test "configPath ends with config.json under the config dir" {
    const gpa = std.testing.allocator;
    const p = try common.configPath(gpa);
    defer gpa.free(p);
    try std.testing.expect(std.mem.endsWith(u8, p, "config.json"));
    try std.testing.expect(std.mem.indexOf(u8, p, common.TOOL) != null);
}
