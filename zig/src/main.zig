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

/// The decision a prompt parse yields. Mirrors the three terminal outcomes of
/// the retired hooks/ponytail-mode-tracker.js:
///   - `.set`   — persist a runtime mode (lite/full/ultra/review) to the flag
///   - `.clear` — delete the flag (deactivation: `/ponytail off`, "stop ponytail")
///   - `.none`  — no ponytail command in the prompt; do nothing
pub const Action = union(enum) {
    set: []const u8,
    clear,
    none,
};

/// Lowercase ASCII into `buf`, returning the written slice. Modes/commands are
/// ASCII-only, matching the JS `.toLowerCase()` on the prompt before matching.
/// Returns null if the source does not fit (caller treats as no-match).
fn lowerInto(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    for (s, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..s.len];
}

/// True if the whole (trimmed, lowercased) message is a standalone deactivation
/// command. EXACT port of hooks/ponytail-config.js isDeactivationCommand:
///   t = text.trim().toLowerCase().replace(/[.!?\s]+$/, '')
///   t === 'stop ponytail' || t === 'normal mode'
/// Matching the phrase only as the WHOLE message (not anywhere inside it) avoids
/// turning ponytail off mid-task for requests like "add a normal mode toggle".
fn isDeactivationCommand(lowered: []const u8) bool {
    // Strip trailing run of [.!?\s] like the JS regex `[.!?\s]+$`.
    var end = lowered.len;
    while (end > 0) {
        const ch = lowered[end - 1];
        if (ch == '.' or ch == '!' or ch == '?' or ch == ' ' or
            ch == '\t' or ch == '\r' or ch == '\n')
        {
            end -= 1;
        } else break;
    }
    const t = lowered[0..end];
    return std.mem.eql(u8, t, "stop ponytail") or std.mem.eql(u8, t, "normal mode");
}

/// Map a resolved default mode to an Action: "off" → clear, anything else →
/// set. Mirrors the JS branch `if (mode && mode !== 'off') setMode(mode); else
/// if (mode === 'off') clearMode()` after `mode = getDefaultMode()`. A non-empty
/// non-off default is set verbatim (the statusline whitelists it on render).
fn setOrClear(default_mode: []const u8) Action {
    if (default_mode.len == 0) return .none;
    if (std.mem.eql(u8, default_mode, "off")) return .clear;
    return .{ .set = default_mode };
}

/// Parse a prompt into an Action. EXACT port of the retired
/// hooks/ponytail-mode-tracker.js command surface:
///
///   - Recognizes a leading command sigil `/`, `@`, or `$` (the documented Codex
///     `@ponytail ...` form and the `$ponytail` shell-style form both map to `/`).
///   - `/ponytail-review` and `/ponytail:ponytail-review` → set review.
///   - `/ponytail` / `/ponytail:ponytail` with arg:
///       lite|full|ultra → that mode; off → clear; anything else → default mode.
///   - Standalone "stop ponytail" / "normal mode" (whole message) → clear.
///
/// `default_mode` is the resolved configured default (common.getDefaultMode),
/// substituted for the bare `/ponytail` and unknown-arg cases. It is validated
/// by the caller; if it is itself "off"/"review"/etc. the Action faithfully
/// carries it, matching the JS which fed getDefaultMode() straight into setMode.
fn parsePrompt(buf: []u8, prompt: []const u8, default_mode: []const u8) Action {
    const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
    const lowered = lowerInto(buf, trimmed) orelse return .none;

    // Slash/at/dollar-prefixed ponytail command. The JS regex is /^[/@$]ponytail/.
    if (lowered.len >= 1) {
        const sigil = lowered[0];
        if (sigil == '/' or sigil == '@' or sigil == '$') {
            // First token: command word. JS splits on /\s+/ and takes parts[0],
            // then strips a leading @ or $ → '/'. tokenizeAny over whitespace.
            var it = std.mem.tokenizeAny(u8, lowered, " \t\r\n");
            const first = it.next() orelse return .none;
            // Normalize leading @ / $ to '/' so @ponytail / $ponytail == /ponytail.
            // first[0] is the sigil we already matched, so this always rewrites it.
            var cmd_buf: [64]u8 = undefined;
            if (first.len > cmd_buf.len) return .none;
            @memcpy(cmd_buf[0..first.len], first);
            cmd_buf[0] = '/';
            const cmd = cmd_buf[0..first.len];

            const review_cmd = "/" ++ TOOL ++ "-review";
            const review_ns_cmd = "/" ++ TOOL ++ ":" ++ TOOL ++ "-review";
            if (std.mem.eql(u8, cmd, review_cmd) or std.mem.eql(u8, cmd, review_ns_cmd)) {
                return .{ .set = "review" };
            }

            const bare_cmd = "/" ++ TOOL;
            const ns_cmd = "/" ++ TOOL ++ ":" ++ TOOL;
            if (std.mem.eql(u8, cmd, bare_cmd) or std.mem.eql(u8, cmd, ns_cmd)) {
                const arg = it.next() orelse return setOrClear(default_mode); // bare → default
                if (std.mem.eql(u8, arg, "off")) return .clear;
                if (std.mem.eql(u8, arg, "lite")) return .{ .set = "lite" };
                if (std.mem.eql(u8, arg, "full")) return .{ .set = "full" };
                if (std.mem.eql(u8, arg, "ultra")) return .{ .set = "ultra" };
                // Unknown arg → default mode, mirroring the JS `else mode = getDefaultMode()`.
                return setOrClear(default_mode);
            }
            // A `/<tool>foo` prefix that is neither the bare nor -review command
            // falls through to the deactivation check (it can't be one), so the
            // wrong "/ponytailx ultra" never activates a mode.
        }
    }

    // Standalone deactivation phrase. Checked even when no command sigil matched,
    // mirroring the JS which evaluates isDeactivationCommand unconditionally.
    if (isDeactivationCommand(lowered)) return .clear;

    return .none;
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

    // Resolve the configured default for the bare `/ponytail` / unknown-arg cases.
    // Owned; freed below. On env/config failure fall back to DEFAULT_MODE so a
    // bare command still activates something (matching the JS getDefaultMode
    // fallback). The buffer for the lowercased prompt is allocator-backed so the
    // whole-message deactivation check works regardless of prompt length.
    const default_mode = common.getDefaultMode(gpa) catch gpa.dupe(u8, common.DEFAULT_MODE) catch return;
    defer gpa.free(default_mode);

    const lower_buf = gpa.alloc(u8, prompt.len) catch return;
    defer gpa.free(lower_buf);

    const action = parsePrompt(lower_buf, prompt, default_mode);

    // Silent-fail if env is missing/invalid (e.g. no HOME) — a hook must never
    // bubble an error out of main and disturb prompt submission.
    const path = common.flagPath(gpa) catch return;
    defer gpa.free(path);

    const mode = switch (action) {
        .none => return,
        .clear => {
            // Deactivation: delete the flag (best-effort) and emit the "MODE OFF"
            // host output, mirroring the JS clearMode + writeHookOutput('off').
            common.clearFlag(path);
            const off_ctx = std.fmt.allocPrint(
                gpa,
                "{s} MODE OFF",
                .{common.TOOL_UPPER},
            ) catch return;
            defer gpa.free(off_ctx);
            common.writeHookOutput(gpa, "UserPromptSubmit", "off", off_ctx);
            return;
        },
        .set => |m| m,
    };

    common.safeWriteFlag(gpa, path, mode) catch return; // silent-fail on FS errors

    // Per-turn reinforcement context. Mirrors hooks/ponytail-mode-tracker.js,
    // which passes the plain text "PONYTAIL MODE CHANGED — level: <mode>" to
    // writeHookOutput. Routing it through common.writeHookOutput means the plain
    // Claude host gets the raw text injected as additionalContext, while Codex /
    // Copilot get their JSON envelopes (systemMessage / additionalContext) — the
    // host output contracts the JS runtime shim enforces.
    const context = std.fmt.allocPrint(
        gpa,
        "{s} MODE CHANGED — level: {s}",
        .{ common.TOOL_UPPER, mode },
    ) catch return;
    defer gpa.free(context);
    common.writeHookOutput(gpa, "UserPromptSubmit", mode, context);
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// Test helper: parse `prompt` with a stack buffer + given default, asserting
/// the buffer is big enough (tests use short prompts).
fn parseT(prompt: []const u8, default_mode: []const u8) Action {
    var buf: [256]u8 = undefined;
    std.debug.assert(prompt.len <= buf.len);
    return parsePrompt(buf[0..], prompt, default_mode);
}

/// Assert an Action is `.set` with the expected mode.
fn expectSet(expected: []const u8, action: Action) !void {
    switch (action) {
        .set => |m| try std.testing.expectEqualStrings(expected, m),
        else => return error.NotSet,
    }
}

test "parsePrompt slash level args" {
    // Bare /ponytail → resolved default (here we pass "full").
    try expectSet("full", parseT("/" ++ TOOL, "full"));
    try expectSet("lite", parseT("/" ++ TOOL ++ " lite", "full"));
    try expectSet("full", parseT("/" ++ TOOL ++ " full", "lite"));
    try expectSet("ultra", parseT("/" ++ TOOL ++ " ultra", "full"));
    // Unknown arg → default mode (mirrors JS `else mode = getDefaultMode()`).
    try expectSet("lite", parseT("/" ++ TOOL ++ " wenyan", "lite"));
    try expectSet("full", parseT("/" ++ TOOL ++ " bogus", "full"));
}

test "parsePrompt /ponytail off and namespaced forms" {
    // `/ponytail off` → clear.
    try std.testing.expectEqual(Action.clear, parseT("/" ++ TOOL ++ " off", "full"));
    // Namespaced `/ponytail:ponytail` (plugin-qualified) behaves like bare.
    try expectSet("ultra", parseT("/" ++ TOOL ++ ":" ++ TOOL ++ " ultra", "full"));
    try expectSet("full", parseT("/" ++ TOOL ++ ":" ++ TOOL, "full"));
    try std.testing.expectEqual(Action.clear, parseT("/" ++ TOOL ++ ":" ++ TOOL ++ " off", "full"));
}

test "parsePrompt /ponytail-review (and namespaced) → review" {
    try expectSet("review", parseT("/" ++ TOOL ++ "-review", "full"));
    try expectSet("review", parseT("/" ++ TOOL ++ "-review some arg", "full"));
    try expectSet("review", parseT("/" ++ TOOL ++ ":" ++ TOOL ++ "-review", "full"));
}

test "parsePrompt @ponytail and $ponytail sigils (Codex / shell forms)" {
    // Documented Codex `@ponytail ...` form maps to `/ponytail ...`.
    try expectSet("ultra", parseT("@" ++ TOOL ++ " ultra", "full"));
    try expectSet("full", parseT("@" ++ TOOL, "full"));
    try expectSet("review", parseT("@" ++ TOOL ++ "-review", "full"));
    // `$ponytail` shell-style form likewise.
    try expectSet("lite", parseT("$" ++ TOOL ++ " lite", "full"));
    try std.testing.expectEqual(Action.clear, parseT("@" ++ TOOL ++ " off", "full"));
}

test "parsePrompt case-insensitive and trimmed (mirrors JS .trim().toLowerCase())" {
    try expectSet("ultra", parseT("  /" ++ "PONYTAIL ULTRA  ", "full"));
    try expectSet("review", parseT("/PONYTAIL-Review", "full"));
}

test "parsePrompt standalone deactivation phrases → clear" {
    try std.testing.expectEqual(Action.clear, parseT("stop ponytail", "full"));
    try std.testing.expectEqual(Action.clear, parseT("normal mode", "full"));
    // Trailing punctuation/whitespace stripped like the JS /[.!?\s]+$/.
    try std.testing.expectEqual(Action.clear, parseT("Stop Ponytail!", "full"));
    try std.testing.expectEqual(Action.clear, parseT("normal mode.  ", "full"));
    // Phrase embedded in a larger message must NOT deactivate (regression #162).
    try std.testing.expectEqual(Action.none, parseT("add a normal mode toggle", "full"));
    try std.testing.expectEqual(Action.none, parseT("please stop ponytail from yelling", "full"));
}

test "parsePrompt non-commands → none" {
    try std.testing.expectEqual(Action.none, parseT("hello world", "full"));
    // Prefix that is neither bare nor -review must not activate (the old bug).
    try std.testing.expectEqual(Action.none, parseT("/" ++ TOOL ++ "x ultra", "full"));
    // A sigil on an unrelated word is ignored.
    try std.testing.expectEqual(Action.none, parseT("@mention someone", "full"));
}

test "parsePrompt default of 'off' clears (mirrors getDefaultMode→off branch)" {
    // If the resolved default is "off", a bare /ponytail clears rather than sets.
    try std.testing.expectEqual(Action.clear, parseT("/" ++ TOOL, "off"));
    try std.testing.expectEqual(Action.clear, parseT("/" ++ TOOL ++ " bogus", "off"));
}

test "extractPrompt pulls prompt field" {
    const gpa = std.testing.allocator;
    const got = extractPrompt(gpa, "{\"prompt\":\"/" ++ TOOL ++ " ultra\",\"x\":1}").?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/" ++ TOOL ++ " ultra", got);
    try std.testing.expect(extractPrompt(gpa, "not json") == null);
}
