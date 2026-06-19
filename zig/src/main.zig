//! Caveman/Ponytail UserPromptSubmit hook — Zig 0.16.
//!
//! Replaces the Node hook. Reads the hook JSON event on stdin, detects a
//! `/<tool> <level>` slash command, persists the mode through a SYMLINK-SAFE
//! flag write, and emits the hookSpecificOutput JSON the harness injects back
//! as per-turn reinforcement.
//!
//! The security core (symlink-safe flag write, mode whitelist, path
//! resolution) now lives in `common.zig`, shared with the SessionStart
//! activate binary and the statusline binary. This file is the
//! UserPromptSubmit entry point only.
//!
//! Written against the stable libc C ABI (std.c + a couple of extern decls)
//! rather than the in-flight std.Io surface: a hook binary links libc anyway
//! and this keeps it pinned to a stable interface.

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

const TOOL = common.TOOL;

/// Extract the "prompt" string from the hook JSON via std.json (correct, not
/// hand-rolled). Returns an owned copy or null.
fn extractPrompt(gpa: std.mem.Allocator, input: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, input, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const p = obj.get("prompt") orelse return null;
    const s = switch (p) {
        .string => |str| str,
        else => return null,
    };
    return gpa.dupe(u8, s) catch null;
}

/// Parse `/<tool> <level>` → mode, or null. Mirrors the JS mode-tracker.
fn parseSlashMode(prompt: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const cmd = "/" ++ TOOL;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return null;
    // Exact first-token match — startsWith would accept "/<tool>x ..." and
    // wrongly activate mode parsing.
    if (!std.mem.eql(u8, first, cmd)) return null;
    const arg = it.next() orelse return "full"; // bare → default
    if (common.isValidMode(arg)) return arg;
    return null;
}

/// Read all of stdin into an owned buffer using raw read(2).
fn readStdin(gpa: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(gpa);
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const input = readStdin(gpa) catch return; // silent-fail contract
    defer gpa.free(input);

    const prompt = extractPrompt(gpa, input) orelse return;
    defer gpa.free(prompt);

    const mode = parseSlashMode(prompt) orelse return;

    // Silent-fail if env is missing/invalid (e.g. no HOME) — a hook must never
    // bubble an error out of main and disturb prompt submission.
    const path = common.flagPath(gpa) catch return;
    defer gpa.free(path);
    common.safeWriteFlag(gpa, path, mode) catch return; // silent-fail on FS errors

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":\"");
    try out.appendSlice(gpa, TOOL);
    try out.appendSlice(gpa, " mode active: ");
    try out.appendSlice(gpa, mode);
    try out.appendSlice(gpa, "\"}}");
    common.writeStdout(out.items);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "parseSlashMode" {
    try std.testing.expectEqualStrings("full", parseSlashMode("/" ++ TOOL).?);
    try std.testing.expectEqualStrings("ultra", parseSlashMode("/" ++ TOOL ++ " ultra").?);
    try std.testing.expect(parseSlashMode("/" ++ TOOL ++ " wenyan") == null); // no wenyan in ponytail
    try std.testing.expect(parseSlashMode("hello world") == null);
    try std.testing.expect(parseSlashMode("/" ++ TOOL ++ " bogus") == null);
    try std.testing.expect(parseSlashMode("/" ++ TOOL ++ "x ultra") == null); // prefix, not exact
}

test "extractPrompt pulls prompt field" {
    const gpa = std.testing.allocator;
    const got = extractPrompt(gpa, "{\"prompt\":\"/" ++ TOOL ++ " ultra\",\"x\":1}").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/" ++ TOOL ++ " ultra", got);
    try std.testing.expect(extractPrompt(gpa, "not json") == null);
}
