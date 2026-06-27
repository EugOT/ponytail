//! Ponytail MCP server — Zig 0.16.
//!
//! Hand-rolled port of ponytail-mcp/{index.js,instructions.js}. The JS server
//! uses @modelcontextprotocol/sdk + zod; a Zig MCP server has no SDK, so it
//! speaks the JSON-RPC 2.0 wire protocol BY HAND over stdio.
//!
//! Transport: newline-delimited JSON-RPC, matching what the SDK's
//! StdioServerTransport emits for stdio (one JSON object per line, '\n'
//! framed — no Content-Length headers). We read line-by-line, parse each as a
//! JSON-RPC request, dispatch, and write the id-matched result on its own line.
//!
//! Surface (mirrors index.js):
//!   - PROMPT  `ponytail`            — prompts/get returns the ruleset as a
//!                                     user-role text message.
//!   - TOOL    `ponytail_instructions` (input {mode?}) — tools/call runs
//!     buildInstructions(resolveMode(mode)) and returns
//!     {content:[text], structuredContent:{mode, instructions}}.
//!
//! The ruleset body is the same one common.getInstructions builds, over the
//! ponytail SKILL.md embedded at comptime (wired in build.zig as `skill_md`,
//! exactly like activate.zig). resolveMode mirrors instructions.js resolveMode:
//! runtime-normalize the request, fall back through the configured default to
//! "full", never serving "off"/"review".
//!
//! Written against the stable libc C ABI + std.json (NOT std.Io), consistent
//! with the rest of the binaries. Silent on malformed input lines (skip them);
//! never crashes on a single bad request.

const std = @import("std");
const common = @import("common.zig");
const c = common.c;

const TOOL = common.TOOL;
const TOOL_UPPER = common.TOOL_UPPER;
const SKILL_MD = @embedFile("skill_md");

const SERVER_NAME = TOOL;
const SERVER_VERSION = "0.1.0";
const PROTOCOL_VERSION = "2024-11-05";

// The three intensities the server offers. Mirrors instructions.js MODES.
// "off"/"review" are never served — resolveMode collapses them to a runtime mode.
const SERVED_MODES = [_][]const u8{ "lite", "full", "ultra" };

// ── Mode resolution (port of instructions.js resolveMode / buildInstructions) ──

/// Trim + lowercase `mode` into `buf`; return the slice iff it is a RUNTIME_MODE
/// (off|lite|full|ultra), else null. Mirrors ponytail-config.js normalizeMode —
/// the same predicate common.zig uses internally, re-implemented here so this
/// file does not reach into common's private helpers.
fn normalizeRuntimeMode(buf: []u8, mode: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, mode, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    for (trimmed, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lowered = buf[0..trimmed.len];
    const runtime = [_][]const u8{ "off", "lite", "full", "ultra" };
    for (runtime) |m| if (std.mem.eql(u8, m, lowered)) return lowered;
    return null;
}

/// Resolve a requested mode to a served runtime intensity. EXACT port of
/// instructions.js resolveMode:
///   asked = normalizeMode(requested)
///   if asked && asked !== "off" return asked
///   fallback = normalizeMode(getDefaultMode())
///   return (fallback && fallback !== "off") ? fallback : "full"
/// Returns an owned, lowercased copy the caller frees.
fn resolveMode(gpa: std.mem.Allocator, requested: ?[]const u8) ![]u8 {
    var abuf: [16]u8 = undefined;
    if (requested) |req| {
        if (normalizeRuntimeMode(&abuf, req)) |asked| {
            if (!std.mem.eql(u8, asked, "off")) return gpa.dupe(u8, asked);
        }
    }

    // getDefaultMode returns a STATUSLINE mode (off|lite|full|ultra|review);
    // re-normalize through runtime-mode semantics like the JS does
    // (normalizeMode(getDefaultMode())), so "review" collapses to "full".
    const dflt = try common.getDefaultMode(gpa);
    defer gpa.free(dflt);
    var fbuf: [16]u8 = undefined;
    if (normalizeRuntimeMode(&fbuf, dflt)) |fallback| {
        if (!std.mem.eql(u8, fallback, "off")) return gpa.dupe(u8, fallback);
    }
    return gpa.dupe(u8, "full");
}

/// buildInstructions(requested) = getPonytailInstructions(resolveMode(requested)).
/// getInstructions resolves again internally; resolveMode is idempotent on a
/// served runtime mode, so the double-resolve is a no-op (matches the JS).
fn buildInstructions(gpa: std.mem.Allocator, mode: []const u8) ![]u8 {
    return common.getInstructions(gpa, SKILL_MD, mode);
}

// ── JSON-RPC plumbing ─────────────────────────────────────────────────────────

/// A parsed JSON-RPC request id. JSON-RPC ids may be a string, a number, or
/// null/absent (notification). We capture the raw JSON token so the reply echoes
/// it back byte-for-byte (numbers stay numbers, strings stay strings).
const Id = union(enum) {
    none, // no id field → notification, no reply
    raw: []const u8, // owned raw JSON literal ("5", "\"abc\"", "null")
};

fn dupeIdRaw(gpa: std.mem.Allocator, v: std.json.Value) !Id {
    // Re-serialize the id value to its canonical JSON literal so the response
    // id is value-equal to the request id (not necessarily byte-identical to
    // the input, but JSON-RPC matches on value).
    // std.json.Stringify.valueAlloc allocates an owned slice — no manual
    // ArrayList plumbing needed.
    const owned = try std.json.Stringify.valueAlloc(gpa, v, .{});
    return .{ .raw = owned };
}

fn freeId(gpa: std.mem.Allocator, id: Id) void {
    switch (id) {
        .raw => |r| gpa.free(r),
        .none => {},
    }
}

/// Append `"id":<literal>` (the raw id JSON) to an envelope.
fn appendId(gpa: std.mem.Allocator, out: *std.ArrayList(u8), id: Id) !void {
    try out.appendSlice(gpa, "\"id\":");
    switch (id) {
        .raw => |r| try out.appendSlice(gpa, r),
        .none => try out.appendSlice(gpa, "null"),
    }
}

/// Append a JSON-escaped string body (between-quotes bytes). Reuses the same
/// escaping contract as common.appendJsonStringBody, re-implemented locally so
/// we don't widen common's public surface.
fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            else => {
                if (ch < 0x20) {
                    try out.appendSlice(gpa, "\\u00");
                    const hex = "0123456789abcdef";
                    try out.append(gpa, hex[(ch >> 4) & 0xf]);
                    try out.append(gpa, hex[ch & 0xf]);
                } else {
                    try out.append(gpa, ch);
                }
            },
        }
    }
    try out.append(gpa, '"');
}

/// Wrap a result body: `{"jsonrpc":"2.0","id":<id>,"result":<body>}`.
fn buildResult(gpa: std.mem.Allocator, id: Id, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",");
    try appendId(gpa, &out, id);
    try out.appendSlice(gpa, ",\"result\":");
    try out.appendSlice(gpa, body);
    try out.append(gpa, '}');
    return out.toOwnedSlice(gpa);
}

/// Wrap an error: `{"jsonrpc":"2.0","id":<id>,"error":{"code":...,"message":...}}`.
fn buildError(gpa: std.mem.Allocator, id: Id, code: i64, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"jsonrpc\":\"2.0\",");
    try appendId(gpa, &out, id);
    try out.appendSlice(gpa, ",\"error\":{\"code\":");
    const code_str = try std.fmt.allocPrint(gpa, "{d}", .{code});
    defer gpa.free(code_str);
    try out.appendSlice(gpa, code_str);
    try out.appendSlice(gpa, ",\"message\":");
    try appendJsonString(gpa, &out, message);
    try out.appendSlice(gpa, "}}");
    return out.toOwnedSlice(gpa);
}

// ── Method result bodies ──────────────────────────────────────────────────────

/// initialize → serverInfo + capabilities {prompts:{}, tools:{}}.
fn resultInitialize(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"protocolVersion\":");
    try appendJsonString(gpa, &out, PROTOCOL_VERSION);
    try out.appendSlice(gpa, ",\"capabilities\":{\"prompts\":{},\"tools\":{}},\"serverInfo\":{\"name\":");
    try appendJsonString(gpa, &out, SERVER_NAME);
    try out.appendSlice(gpa, ",\"version\":");
    try appendJsonString(gpa, &out, SERVER_VERSION);
    try out.appendSlice(gpa, "}}");
    return out.toOwnedSlice(gpa);
}

/// prompts/list → the single `ponytail` prompt with its `mode` argument.
fn resultPromptsList(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\{"prompts":[{"name":"ponytail","title":"Ponytail mode","description":"Lazy senior dev instructions: YAGNI, stdlib first, the smallest correct change.","arguments":[{"name":"mode","description":"Ponytail intensity: lite, full, or ultra. Omit for the configured default.","required":false}]}]}
    );
}

/// prompts/get → the ruleset as a user-role text message. Mirrors index.js
/// registerPrompt: messages:[{role:"user",content:{type:"text",text:build(mode)}}].
/// Note: index.js passes the RAW mode to buildInstructions (no resolveMode at
/// the prompt layer); buildInstructions resolves it internally.
fn resultPromptsGet(gpa: std.mem.Allocator, mode: ?[]const u8) ![]u8 {
    const resolved = try resolveMode(gpa, mode);
    defer gpa.free(resolved);
    const text = try buildInstructions(gpa, resolved);
    defer gpa.free(text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"description\":");
    try appendJsonString(gpa, &out, "Lazy senior dev instructions: YAGNI, stdlib first, the smallest correct change.");
    try out.appendSlice(gpa, ",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":");
    try appendJsonString(gpa, &out, text);
    try out.appendSlice(gpa, "}}]}");
    return out.toOwnedSlice(gpa);
}

/// tools/list → the `ponytail_instructions` tool with its input/output schemas
/// and annotations. Mirrors index.js registerTool.
fn resultToolsList(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\{"tools":[{"name":"ponytail_instructions","title":"Ponytail instructions","description":"Return the Ponytail ruleset for the given intensity (lite, full, or ultra).","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["lite","full","ultra"],"description":"Ponytail intensity: lite, full, or ultra. Omit for the configured default."}}},"outputSchema":{"type":"object","properties":{"mode":{"type":"string"},"instructions":{"type":"string"}},"required":["mode","instructions"]},"annotations":{"readOnlyHint":true,"openWorldHint":false}}]}
    );
}

/// tools/call ponytail_instructions → run buildInstructions(resolveMode(mode)),
/// return {content:[{type:text,text:instructions}], structuredContent:{mode, instructions}}.
/// EXACT port of index.js registerTool handler.
fn resultToolsCall(gpa: std.mem.Allocator, mode: ?[]const u8) ![]u8 {
    const resolved = try resolveMode(gpa, mode);
    defer gpa.free(resolved);
    const instructions = try buildInstructions(gpa, resolved);
    defer gpa.free(instructions);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "{\"content\":[{\"type\":\"text\",\"text\":");
    try appendJsonString(gpa, &out, instructions);
    try out.appendSlice(gpa, "}],\"structuredContent\":{\"mode\":");
    try appendJsonString(gpa, &out, resolved);
    try out.appendSlice(gpa, ",\"instructions\":");
    try appendJsonString(gpa, &out, instructions);
    try out.appendSlice(gpa, "}}");
    return out.toOwnedSlice(gpa);
}

// ── Request extraction ────────────────────────────────────────────────────────

/// Pull the `params.arguments.mode` (prompts/get) or `params.arguments.mode`
/// (tools/call) string. Both index.js handlers read `mode` off the destructured
/// args. Returns a borrow into `root`'s arena (valid until parsed.deinit), or null.
fn extractMode(params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    const pobj = switch (p) {
        .object => |o| o,
        else => return null,
    };
    const args = pobj.get("arguments") orelse return null;
    const aobj = switch (args) {
        .object => |o| o,
        else => return null,
    };
    const m = aobj.get("mode") orelse return null;
    return switch (m) {
        .string => |s| s,
        else => null,
    };
}

/// Pull `params.name` (tools/call tool name, prompts/get prompt name).
fn extractName(params: ?std.json.Value) ?[]const u8 {
    const p = params orelse return null;
    const pobj = switch (p) {
        .object => |o| o,
        else => return null,
    };
    const n = pobj.get("name") orelse return null;
    return switch (n) {
        .string => |s| s,
        else => null,
    };
}

// ── Dispatch ──────────────────────────────────────────────────────────────────

/// Handle one parsed JSON-RPC request object. Returns the owned response line
/// (without trailing newline), or null for notifications / unparseable input
/// (no reply). The caller frees a non-null result.
///
/// Exposed (not pub) for tests; the public seam is handleLine.
fn dispatch(gpa: std.mem.Allocator, root: std.json.Value) !?[]u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };

    const method_v = obj.get("method") orelse return null;
    const method = switch (method_v) {
        .string => |s| s,
        else => return null,
    };

    // id present → request (reply); absent → notification (ignore).
    const id: Id = if (obj.get("id")) |idv| try dupeIdRaw(gpa, idv) else .none;
    defer freeId(gpa, id);

    // Notifications (no id) get no reply, whatever the method.
    if (id == .none) return null;

    const params = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        const body = try resultInitialize(gpa);
        defer gpa.free(body);
        return try buildResult(gpa, id, body);
    } else if (std.mem.eql(u8, method, "ping")) {
        return try buildResult(gpa, id, "{}");
    } else if (std.mem.eql(u8, method, "prompts/list")) {
        const body = try resultPromptsList(gpa);
        defer gpa.free(body);
        return try buildResult(gpa, id, body);
    } else if (std.mem.eql(u8, method, "prompts/get")) {
        const name = extractName(params);
        if (name == null or !std.mem.eql(u8, name.?, "ponytail")) {
            return try buildError(gpa, id, -32602, "Unknown prompt");
        }
        const body = try resultPromptsGet(gpa, extractMode(params));
        defer gpa.free(body);
        return try buildResult(gpa, id, body);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        const body = try resultToolsList(gpa);
        defer gpa.free(body);
        return try buildResult(gpa, id, body);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const name = extractName(params);
        if (name == null or !std.mem.eql(u8, name.?, "ponytail_instructions")) {
            return try buildError(gpa, id, -32602, "Unknown tool");
        }
        const body = try resultToolsCall(gpa, extractMode(params));
        defer gpa.free(body);
        return try buildResult(gpa, id, body);
    }

    // Unknown method on a request → JSON-RPC "Method not found".
    return try buildError(gpa, id, -32601, "Method not found");
}

/// Parse one line as JSON, dispatch, return the owned response line or null.
/// Malformed JSON on a line is skipped (null) — never crashes the loop.
fn handleLine(gpa: std.mem.Allocator, line: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, trimmed, .{}) catch return null;
    defer parsed.deinit();
    return dispatch(gpa, parsed.value);
}

/// Write a response line + '\n' to stdout.
fn emitLine(line: []const u8) void {
    common.writeStdout(line);
    common.writeStdout("\n");
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Read stdin, dispatch each '\n'-framed JSON-RPC request. We buffer until a
    // newline, hand the line to handleLine, emit the reply (if any), repeat.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n < 0) return; // read error → bail (transport gone)
        if (n == 0) break; // EOF → flush any trailing partial line below
        const chunk = buf[0..@intCast(n)];
        var start: usize = 0;
        for (chunk, 0..) |ch, i| {
            if (ch == '\n') {
                line.appendSlice(gpa, chunk[start..i]) catch return;
                processLine(gpa, line.items);
                line.clearRetainingCapacity();
                start = i + 1;
            }
        }
        line.appendSlice(gpa, chunk[start..]) catch return;
    }
    // Trailing line with no newline at EOF (some transports omit the final \n).
    if (line.items.len > 0) processLine(gpa, line.items);
}

fn processLine(gpa: std.mem.Allocator, line: []const u8) void {
    const resp = handleLine(gpa, line) catch return;
    if (resp) |r| {
        defer gpa.free(r);
        emitLine(r);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────
//
// The instruction body itself (filterSkillBodyForMode / getInstructions) is
// tested in common.zig. Here we test the MCP-specific glue: resolveMode
// normalization, id-matched JSON-RPC envelopes, and that the tools/call payload
// carries the same instructions body getInstructions produces.

const testing = std.testing;

fn dispatchJson(gpa: std.mem.Allocator, json: []const u8) !?[]u8 {
    return handleLine(gpa, json);
}

test "resolveMode normalizes valid intensities idempotently" {
    const gpa = testing.allocator;
    inline for (.{ "lite", "full", "ultra" }) |m| {
        const r = try resolveMode(gpa, m);
        defer gpa.free(r);
        try testing.expectEqualStrings(m, r);
    }
}

test "resolveMode trims + lowercases" {
    const gpa = testing.allocator;
    const r = try resolveMode(gpa, "  ULTRA \n");
    defer gpa.free(r);
    try testing.expectEqualStrings("ultra", r);
}

test "resolveMode never serves off/review/junk — always a served mode" {
    const gpa = testing.allocator;
    // Mirrors the JS test: off/review/nonsense/empty all fall back to a served
    // runtime mode (default is "full" with no env/config in the test env).
    for ([_]?[]const u8{ "off", "review", "nonsense", "", null }) |input| {
        const r = try resolveMode(gpa, input);
        defer gpa.free(r);
        var served = false;
        for (SERVED_MODES) |m| if (std.mem.eql(u8, m, r)) {
            served = true;
        };
        try testing.expect(served);
    }
}

test "initialize: id-matched envelope with serverInfo + capabilities" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":1") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"prompts\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"tools\":{}") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"" ++ SERVER_NAME ++ "\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"version\":\"" ++ SERVER_VERSION ++ "\"") != null);
}

test "initialize: string id is echoed as a string" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"initialize\"}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"abc\"") != null);
}

test "tools/list lists ponytail_instructions with mode enum" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":2") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"ponytail_instructions\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"enum\":[\"lite\",\"full\",\"ultra\"]") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"readOnlyHint\":true") != null);
}

test "tools/call ponytail_instructions {mode:full}: payload matches getInstructions" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"ponytail_instructions\",\"arguments\":{\"mode\":\"full\"}}}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":3") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"structuredContent\":{\"mode\":\"full\"") != null);

    // The instructions text in the payload must equal getInstructions("full")
    // with JSON-string escaping applied. Build the expected escaped form and
    // assert it appears as the content[0].text value.
    const want = try common.getInstructions(gpa, SKILL_MD, "full");
    defer gpa.free(want);
    var esc: std.ArrayList(u8) = .empty;
    defer esc.deinit(gpa);
    try appendJsonString(gpa, &esc, want);
    // esc includes the surrounding quotes; assert the quoted body is embedded.
    try testing.expect(std.mem.indexOf(u8, resp, esc.items) != null);
    // And the header line is present (sanity on the ruleset body).
    try testing.expect(std.mem.indexOf(u8, resp, TOOL_UPPER ++ " MODE ACTIVE — level: full") != null);
}

test "tools/call unknown tool → -32602 error, id-matched" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":9") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "-32602") != null);
}

test "prompts/get ponytail returns user-role text message = ruleset" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"prompts/get\",\"params\":{\"name\":\"ponytail\",\"arguments\":{\"mode\":\"ultra\"}}}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":4") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"type\":\"text\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, TOOL_UPPER ++ " MODE ACTIVE — level: ultra") != null);
}

test "prompts/list lists the ponytail prompt" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"prompts/list\"}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"ponytail\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"arguments\":[{\"name\":\"mode\"") != null);
}

test "notification (no id) gets no reply" {
    const gpa = testing.allocator;
    const resp = try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    try testing.expect(resp == null);
}

test "unknown method on a request → -32601" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"bogus/method\"}")).?;
    defer gpa.free(resp);
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":7") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "-32601") != null);
}

test "malformed JSON line is skipped (null), no crash" {
    const gpa = testing.allocator;
    try testing.expect((try dispatchJson(gpa, "not json at all")) == null);
    try testing.expect((try dispatchJson(gpa, "")) == null);
    try testing.expect((try dispatchJson(gpa, "   \n")) == null);
}

test "tools/call with omitted mode resolves to a served default" {
    const gpa = testing.allocator;
    const resp = (try dispatchJson(gpa, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"ponytail_instructions\",\"arguments\":{}}}")).?;
    defer gpa.free(resp);
    // structuredContent.mode must be one of the served modes.
    var found = false;
    inline for (.{ "lite", "full", "ultra" }) |m| {
        const needle = "\"structuredContent\":{\"mode\":\"" ++ m ++ "\"";
        if (std.mem.indexOf(u8, resp, needle) != null) found = true;
    }
    try testing.expect(found);
}
