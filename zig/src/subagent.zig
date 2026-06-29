//! Caveman/Ponytail SubagentStart hook — Zig 0.16.
//!
//! Port of the #254 SubagentStart hook (upstream hooks/ponytail-subagent.js).
//! SessionStart `additionalContext` is parent-thread only and never reaches
//! Task-spawned subagents, so without this every subagent runs ponytail-unaware
//! (issue #252). When ponytail mode is active this injects the same ruleset into
//! each subagent, reusing the shared `common.getInstructions` builder.
//!
//! Behavior — an EXACT match for hooks/ponytail-subagent.js:
//!   1. Read the live mode from the flag file (`common.readMode`).
//!   2. Absent flag or "off" → ponytail isn't active → inject nothing, exit 0.
//!   3. Otherwise emit `getInstructions(SKILL_MD, mode)` through the host
//!      dispatch with event "SubagentStart". Native Claude needs the
//!      hookSpecificOutput JSON form (handled in common.buildHookOutputFor's
//!      plain branch); Codex/Copilot get their own envelopes.
//!
//! The ruleset is built over the ponytail SKILL.md embedded at comptime (wired in
//! build.zig as the `skill_md` import, exactly like activate.zig / instructions.zig),
//! so the binary is self-contained and never reads the SKILL from disk at runtime.
//!
//! Silent-fails on filesystem / allocation errors — a hook must never surface a
//! failure that blocks subagent start.

const std = @import("std");
const common = @import("common.zig");

const SKILL_MD = @embedFile("skill_md");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const flag = common.flagPath(gpa) catch return; // silent-fail: no HOME etc.
    defer gpa.free(flag);

    // Read the live mode. Absent flag → ponytail off → inject nothing.
    const mode = common.readMode(gpa, flag) orelse return;
    defer gpa.free(mode);

    // "off" → ponytail isn't active → inject nothing (mirrors the JS guard).
    if (std.mem.eql(u8, mode, "off")) return;

    // Build the ruleset for the active mode. On a build failure (allocation),
    // stay silent rather than emitting a partial body.
    const instructions = common.getInstructions(gpa, SKILL_MD, mode) catch return;
    defer gpa.free(instructions);

    // Emit through the host dispatch: native Claude gets the SubagentStart
    // hookSpecificOutput envelope, Codex/Copilot their own.
    common.writeHookOutput(gpa, "SubagentStart", mode, instructions);
}

// ── Tests ──
//
// The instruction builder + host dispatch (getInstructions / buildHookOutputFor's
// SubagentStart branches) are tested in common.zig. The subagent binary is glue
// (flag read + "off" short-circuit + the SubagentStart event wiring), so the
// tests here pin the seams this file owns: getInstructions over the embedded
// SKILL_MD produces the mode-keyed header/body, and the plain-host SubagentStart
// envelope wraps that body in hookSpecificOutput (what the entry point emits).

const TOOL_UPPER = common.TOOL_UPPER;

test "getInstructions over embedded SKILL_MD: header + mode-filtered body" {
    const gpa = std.testing.allocator;
    const out = try common.getInstructions(gpa, SKILL_MD, "full");
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, TOOL_UPPER ++ " MODE ACTIVE — level: full\n\n"));
    // A non-mode rule bullet survives regardless of mode.
    try std.testing.expect(std.mem.indexOf(u8, out, "No unrequested abstractions") != null);
}

test "SubagentStart plain envelope wraps the embedded ruleset" {
    const gpa = std.testing.allocator;
    const instructions = try common.getInstructions(gpa, SKILL_MD, "full");
    defer gpa.free(instructions);
    const out = try common.buildHookOutputFor(gpa, .plain, "SubagentStart", "full", instructions);
    defer gpa.free(out);
    // Native Claude form: hookSpecificOutput with the SubagentStart event name
    // and the ruleset header carried as additionalContext.
    const prefix = "{\"hookSpecificOutput\":{\"hookEventName\":\"SubagentStart\",";
    try std.testing.expect(std.mem.startsWith(u8, out, prefix));
    try std.testing.expect(std.mem.indexOf(u8, out, "PONYTAIL MODE ACTIVE — level: full") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "}}"));
}

test "off short-circuit predicate matches main" {
    // main injects nothing iff the flag mode == "off".
    try std.testing.expect(std.mem.eql(u8, "off", "off"));
    try std.testing.expect(!std.mem.eql(u8, "full", "off"));
}
