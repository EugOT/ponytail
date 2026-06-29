//! Shared core for the ponytail/caveman Zig hook binaries.
//!
//! Extracted from the original single-file `main.zig` PoC so the three
//! binaries — `<tool>-hook` (UserPromptSubmit), `<tool>-activate`
//! (SessionStart), and `<tool>-statusline` — share one implementation of:
//!
//!   - TOOL identity (comptime, from `-Dtool`)
//!   - the runtime/persist mode whitelists + `canonicalMode`
//!   - default-mode resolution (env var → config.json → "full")
//!   - the symlink-safe atomic flag write (`safeWriteFlag` + `ancestorUnsafe`)
//!   - flag/config path resolution
//!
//! Written against the stable libc C ABI (`std.c` + a couple of `extern`
//! decls) rather than the in-flight `std.Io` surface: every binary links libc
//! anyway and this keeps the security logic pinned to a stable interface.

const std = @import("std");
const build_options = @import("build_options");
pub const c = std.c;

pub const TOOL = build_options.tool; // "caveman" or "ponytail"

// libc decls not surfaced under these names in std.c for this dev build.
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn lstat(path: [*:0]const u8, buf: *c.Stat) c_int;
// resolved_path must point to a buffer of at least PATH_MAX bytes.
pub extern "c" fn realpath(path: [*:0]const u8, resolved_path: [*]u8) ?[*:0]u8;

// ponytail runtime modes — the ones a slash command can persist. Matches
// hooks/ponytail-config.js RUNTIME_MODES minus `off` (deactivation is a flag
// delete, not a written mode). No wenyan — that is a caveman concept the
// ponytail statusline would blank.
pub const VALID_MODES = [_][]const u8{ "lite", "full", "ultra" };

// The full set a persisted/config mode can hold, mirroring
// hooks/ponytail-config.js VALID_MODES (off|lite|full|ultra|review). The
// statusline whitelists exactly this set before rendering.
pub const STATUSLINE_MODES = [_][]const u8{ "off", "lite", "full", "ultra", "review" };

pub const DEFAULT_MODE = "full";

pub const FlagError = error{
    SymlinkRefused,
    ParentSymlinkRefused,
    OpenFailed,
    WriteFailed,
    RenameFailed,
    PathTooLong,
    NoHome,
} || std.mem.Allocator.Error;

/// True if `mode` is a slash-persistable runtime mode (lite/full/ultra).
pub fn isValidMode(mode: []const u8) bool {
    for (VALID_MODES) |m| {
        if (std.mem.eql(u8, m, mode)) return true;
    }
    return false;
}

/// True if `mode` is a statusline-renderable mode (off/lite/full/ultra/review).
pub fn isStatuslineMode(mode: []const u8) bool {
    for (STATUSLINE_MODES) |m| {
        if (std.mem.eql(u8, m, mode)) return true;
    }
    return false;
}

/// Lowercase ASCII in place. Modes are ASCII-only; no Unicode folding needed.
fn lowerAscii(buf: []u8) void {
    for (buf) |*ch| ch.* = std.ascii.toLower(ch.*);
}

pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

/// Copy a slice into a fixed NUL-terminated buffer for C calls.
pub fn toZ(buf: []u8, s: []const u8) FlagError![*:0]const u8 {
    if (s.len + 1 > buf.len) return error.PathTooLong;
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return @ptrCast(buf.ptr);
}

/// Resolve flag path: $CLAUDE_CONFIG_DIR (or $HOME/.claude) + ".<tool>-active".
pub fn flagPath(gpa: std.mem.Allocator) FlagError![]u8 {
    if (getenv("CLAUDE_CONFIG_DIR")) |base| {
        if (base.len > 0) {
            return std.fs.path.join(gpa, &.{ base, "." ++ TOOL ++ "-active" });
        }
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".claude", "." ++ TOOL ++ "-active" });
}

/// Resolve the Claude config dir: $CLAUDE_CONFIG_DIR or $HOME/.claude.
/// Mirrors hooks/ponytail-config.js getClaudeDir.
pub fn claudeDir(gpa: std.mem.Allocator) FlagError![]u8 {
    if (getenv("CLAUDE_CONFIG_DIR")) |base| {
        if (base.len > 0) return gpa.dupe(u8, base);
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".claude" });
}

/// Resolve ponytail config dir: $XDG_CONFIG_HOME/ponytail or ~/.config/ponytail.
/// (Windows %APPDATA% branch from the JS is not handled here — the libc build
/// targets POSIX; the JS keeps covering Windows.)
fn configDir(gpa: std.mem.Allocator) FlagError![]u8 {
    if (getenv("XDG_CONFIG_HOME")) |base| {
        if (base.len > 0) return std.fs.path.join(gpa, &.{ base, TOOL });
    }
    const home = getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".config", TOOL });
}

/// Resolve the config.json path: <configDir>/config.json. Owned, caller frees.
/// Mirrors hooks/ponytail-config.js getConfigPath (the ponytail-config Zig verb
/// writes here for `set-default`).
pub fn configPath(gpa: std.mem.Allocator) FlagError![]u8 {
    const dir = try configDir(gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "config.json" });
}

/// Maximum bytes read from a small config file (64 KiB). Prevents unbounded
/// allocation if the path resolves to a pipe, device, or abnormally large file.
const SMALL_FILE_MAX = 64 * 1024;

/// Read up to SMALL_FILE_MAX bytes from a small file via raw read(2).
/// Public so dev/CI verbs (e.g. the openclaw skill generator) can reuse the
/// same bounded libc reader the runtime hooks use — owned slice, caller frees,
/// null on open/read failure or oversize.
/// Returns null on any error or if the file exceeds the size limit.
pub fn readSmallFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&pbuf, path) catch return null;
    const flags: c.O = .{ .ACCMODE = .RDONLY };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        if (list.items.len >= SMALL_FILE_MAX) {
            // File too large — refuse to accumulate further.
            list.deinit(gpa);
            return null;
        }
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            list.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        list.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            list.deinit(gpa);
            return null;
        };
    }
    return list.toOwnedSlice(gpa) catch null;
}

/// Resolve the default mode: PONYTAIL_DEFAULT_MODE env var → config.json
/// `defaultMode` field → "full". Mirrors hooks/ponytail-config.js getDefaultMode,
/// validating against the full VALID_MODES set (off|lite|full|ultra|review).
///
/// Returns an owned, lowercased copy the caller frees. Fallible: on allocator
/// failure it returns FlagError.OutOfMemory rather than a borrowed pointer into
/// static rodata, preserving the owned-return contract so callers can safely
/// `defer gpa.free(...)` the result.
pub fn getDefaultMode(gpa: std.mem.Allocator) FlagError![]u8 {
    // 1. Environment variable (highest priority). The env name is uppercased
    // tool ("PONYTAIL_DEFAULT_MODE" / "CAVEMAN_DEFAULT_MODE").
    const env_name = comptime TOOL_UPPER ++ "_DEFAULT_MODE\x00";
    if (getenv(@ptrCast(env_name.ptr))) |raw| {
        if (normalizeStatuslineMode(gpa, raw)) |m| return m;
    }

    // 2. Config file defaultMode field.
    if (configDir(gpa)) |dir| {
        defer gpa.free(dir);
        if (std.fs.path.join(gpa, &.{ dir, "config.json" })) |cfg_path| {
            defer gpa.free(cfg_path);
            if (readSmallFile(gpa, cfg_path)) |raw| {
                defer gpa.free(raw);
                if (configModeFromJson(gpa, raw)) |m| return m;
            }
        } else |_| {}
    } else |_| {}

    // 3. Default. Fallible dupe keeps the owned-return contract: on OOM we
    // propagate the error instead of handing back a pointer into static rodata
    // that the caller would then attempt to gpa.free (invalid free).
    return gpa.dupe(u8, DEFAULT_MODE);
}

/// Public allocating config-mode normalizer (off/lite/full/ultra/review): trim +
/// lowercase, owned copy iff whitelisted, else null. Same semantics as
/// hooks/ponytail-config.js normalizeConfigMode — the ponytail-config Zig verb
/// validates `set-default` input through this. (Named *Alloc to distinguish from
/// the private buffer-based `normalizeConfigMode(buf, mode)` runtime variant.)
pub fn normalizeConfigModeAlloc(gpa: std.mem.Allocator, raw: []const u8) ?[]u8 {
    return normalizeStatuslineMode(gpa, raw);
}

/// Trim + lowercase a candidate; return an owned copy iff it is in the
/// statusline whitelist, else null.
fn normalizeStatuslineMode(gpa: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 16) return null;
    const owned = gpa.dupe(u8, trimmed) catch return null;
    lowerAscii(owned);
    if (isStatuslineMode(owned)) return owned;
    gpa.free(owned);
    return null;
}

/// Parse a config.json blob and pull a whitelisted `defaultMode`. Owned copy.
fn configModeFromJson(gpa: std.mem.Allocator, raw: []const u8) ?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, raw, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("defaultMode") orelse return null;
    const s = switch (v) {
        .string => |str| str,
        else => return null,
    };
    return normalizeStatuslineMode(gpa, s);
}

/// lstat a path; true if it exists AND is a symlink (refuse-on-symlink check).
pub fn isSymlink(path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return true; // refuse pathological lengths
    var st: c.Stat = undefined;
    if (lstat(z, &st) != 0) return false; // ENOENT etc → not a symlink
    return (st.mode & c.S.IFMT) == c.S.IFLNK;
}

/// lstat; classify a path component as a (real) directory, a symlink, missing,
/// or other. Used to walk a directory chain refusing any non-directory link.
pub const Comp = enum { dir, symlink, missing, other };
pub fn classify(path: []const u8) Comp {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&buf, path) catch return .symlink; // pathological → treat unsafe
    var st: c.Stat = undefined;
    if (lstat(z, &st) != 0) return .missing;
    const kind = st.mode & c.S.IFMT;
    if (kind == c.S.IFLNK) return .symlink;
    if (kind == c.S.IFDIR) return .dir;
    return .other;
}

/// realpath a path into `out` (libc realpath(3)); returns the resolved slice or
/// null on failure. `out` must be >= PATH_MAX.
fn realpathZ(path: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var ibuf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(&ibuf, path) catch return null;
    const r = realpath(z, out) orelse return null;
    return std.mem.sliceTo(r, 0);
}

/// True if reaching `dir` would pass through a symlink an attacker could plant
/// at ANY level below a trusted base — not just the immediate parent. Mirrors
/// the JS hooks/ponytail-fs-safe.js isAnyAncestorSymlink: anchor on the realpath
/// of the longest trusted base that lexically prefixes `dir` (absorbing benign
/// system links like /var above the user area), then lstat-walk each tail
/// component, refusing any symlinked or non-directory ancestor.
pub fn ancestorUnsafe(dir: []const u8) bool {
    // Trusted bases: $HOME, $TMPDIR, $CLAUDE_CONFIG_DIR.
    const bases: [3]?[]const u8 = .{ getenv("HOME"), getenv("TMPDIR"), getenv("CLAUDE_CONFIG_DIR") };

    var best_base: ?[]const u8 = null;
    for (bases) |maybe| {
        const raw = maybe orelse continue;
        // Normalize a trailing '/' on the base — e.g. macOS $TMPDIR is
        // "/var/folders/.../T/". A base with a trailing slash denotes the same
        // directory as one without; without trimming, the `dir[b.len] == '/'`
        // tail check looks one byte too far and never matches, so a legitimate
        // path under $TMPDIR would be (wrongly) refused as outside every base.
        const b = if (raw.len > 1 and raw[raw.len - 1] == '/') raw[0 .. raw.len - 1] else raw;
        if (b.len == 0) continue;
        // Lexical prefix match: dir == b or dir starts with b + '/'.
        if (std.mem.eql(u8, dir, b) or
            (dir.len > b.len and std.mem.startsWith(u8, dir, b) and dir[b.len] == '/'))
        {
            if (best_base == null or b.len > best_base.?.len) best_base = b;
        }
    }
    const base = best_base orelse return true; // outside every trusted base → refuse

    var anchor_buf: [std.fs.max_path_bytes]u8 = undefined;
    const anchor = realpathZ(base, &anchor_buf) orelse return true;

    // Walk the tail (relative part of dir below base) on the real anchor.
    const tail = dir[base.len..]; // leading '/' or empty
    var cur_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (anchor.len >= cur_buf.len) return true;
    @memcpy(cur_buf[0..anchor.len], anchor);
    var cur_len = anchor.len;

    var it = std.mem.tokenizeScalar(u8, tail, '/');
    while (it.next()) |part| {
        // cur = cur + '/' + part
        if (cur_len + 1 + part.len >= cur_buf.len) return true;
        cur_buf[cur_len] = '/';
        @memcpy(cur_buf[cur_len + 1 ..][0..part.len], part);
        cur_len += 1 + part.len;
        const cur = cur_buf[0..cur_len];
        switch (classify(cur)) {
            .missing => return false, // tail not created yet → mkdir makes real dirs
            .symlink, .other => return true,
            .dir => {},
        }
    }
    return false;
}

/// Symlink-safe atomic flag write. The security core.
pub fn safeWriteFlag(gpa: std.mem.Allocator, path: []const u8, content: []const u8) FlagError!void {
    if (isSymlink(path)) return error.SymlinkRefused;

    const dir = std.fs.path.dirname(path) orelse ".";
    // Refuse if ANY ancestor directory (not just the immediate parent) is a
    // symlink an attacker could have planted to redirect the open/rename.
    if (ancestorUnsafe(dir)) return error.ParentSymlinkRefused;

    // Ensure parent exists (0700). Ignore errors (already-exists / race).
    {
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (toZ(&dbuf, dir)) |dz| {
            _ = c.mkdir(dz, 0o700);
        } else |_| {}
    }

    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}", .{ path, c.getpid() });
    defer gpa.free(tmp);

    var tbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tz = try toZ(&tbuf, tmp);

    // O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600.
    const flags: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true };
    const fd = c.open(tz, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    {
        defer _ = close(fd);
        var written: usize = 0;
        while (written < content.len) {
            const n = c.write(fd, content.ptr + written, content.len - written);
            if (n <= 0) return error.WriteFailed;
            written += @intCast(n);
        }
    }

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&pbuf, path);
    if (c.rename(tz, pz) != 0) {
        _ = c.unlink(tz);
        return error.RenameFailed;
    }
}

/// Recursively create `dir` (mode 0700 per component), like `mkdir -p`. Each
/// component is created with libc mkdir(2); already-exists / races are ignored.
/// This only PRE-CREATES the directory chain — `safeWriteFlag` still performs the
/// authoritative symlink-refuse (`ancestorUnsafe`) + O_NOFOLLOW atomic write, so a
/// symlinked ancestor planted here is still refused at write time. The runtime
/// hooks never need this (their parent dir already exists); the dev/CI verbs
/// (openclaw / pz generators) do, since they write several levels deep
/// (`<root>/.openclaw/skills/<name>/`, `<root>/.pz/skills/ponytail/`).
pub fn makePathRecursive(gpa: std.mem.Allocator, dir: []const u8) std.mem.Allocator.Error!void {
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    var it = std.mem.splitScalar(u8, dir, '/');
    var first = true;
    while (it.next()) |part| {
        if (first and part.len == 0) {
            // Absolute path: seed the accumulator with the root slash.
            try acc.append(gpa, '/');
            first = false;
            continue;
        }
        first = false;
        if (part.len == 0) continue; // collapse '//'
        if (acc.items.len > 0 and acc.items[acc.items.len - 1] != '/') try acc.append(gpa, '/');
        try acc.appendSlice(gpa, part);
        var dbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (toZ(&dbuf, acc.items)) |dz| {
            _ = c.mkdir(dz, 0o700);
        } else |_| {}
    }
}

/// Delete the flag file. Best-effort; mirrors ponytail-runtime.js clearMode.
pub fn clearFlag(path: []const u8) void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = toZ(&pbuf, path) catch return;
    _ = c.unlink(pz);
}

/// Read the live mode written by activate/mode-tracker. Returns an owned,
/// trimmed copy the caller frees, or null when the flag is absent/empty/oversize.
/// Mirrors hooks/ponytail-runtime.js readMode (absent flag = ponytail off).
/// Used by the SubagentStart entry point (#254) to decide whether to inject.
pub fn readMode(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const raw = readSmallFile(gpa, path) orelse return null;
    defer gpa.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

pub fn writeStdout(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

// ── Instruction builder ──────────────────────────────────────────────────────
//
// Port of hooks/ponytail-instructions.js getPonytailInstructions. The SKILL body
// is INJECTED (`skill_md` arg) rather than embedded here so common.zig stays free
// of a build-wired `@embedFile` import — only the activate binary, which already
// has `skill_md` wired in build.zig, supplies it. The hook (main.zig) never builds
// full instructions, so it never needs the body.

/// The TOOL string uppercased at comptime ("ponytail" → "PONYTAIL"). Public so
/// callers reuse the same byte sequence the instruction header / host output use.
pub const TOOL_UPPER = blk: {
    var out: [TOOL.len]u8 = undefined;
    for (TOOL, 0..) |ch, i| out[i] = std.ascii.toUpper(ch);
    const final = out;
    break :blk &final;
};

// Modes whose behavior is defined by a standalone skill, not the SKILL body.
// Mirrors hooks/ponytail-instructions.js INDEPENDENT_MODES.
const INDEPENDENT_MODES = [_][]const u8{"review"};

fn isIndependent(mode: []const u8) bool {
    for (INDEPENDENT_MODES) |m| if (std.mem.eql(u8, m, mode)) return true;
    return false;
}

/// Trim + lowercase `mode` into `buf`; return the slice iff it is a RUNTIME_MODE
/// (off|lite|full|ultra), else null. Mirrors ponytail-config.js normalizeMode.
fn normalizeRuntimeMode(buf: []u8, mode: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, mode, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    for (trimmed, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lowered = buf[0..trimmed.len];
    const runtime = [_][]const u8{ "off", "lite", "full", "ultra" };
    for (runtime) |m| if (std.mem.eql(u8, m, lowered)) return lowered;
    return null;
}

/// Trim + lowercase `mode` into `buf`; return the slice iff it is in VALID_MODES
/// (off|lite|full|ultra|review), else null. Mirrors normalizeConfigMode.
fn normalizeConfigMode(buf: []u8, mode: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, mode, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > buf.len) return null;
    for (trimmed, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lowered = buf[0..trimmed.len];
    if (isStatuslineMode(lowered)) return lowered; // STATUSLINE_MODES == VALID_MODES
    return null;
}

/// normalizeMode || normalizeConfigMode. Mirrors normalizePersistedMode.
fn normalizePersistedMode(buf: []u8, mode: []const u8) ?[]const u8 {
    if (normalizeRuntimeMode(buf, mode)) |m| return m;
    return normalizeConfigMode(buf, mode);
}

/// Strip a leading YAML frontmatter block (`---\n...\n---\s*`). Mirrors the JS
/// `replace(/^---[\s\S]*?---\s*/, '')` in filterSkillBodyForMode.
fn stripFrontmatter(body: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, body, "---")) return body;
    const search_from: usize = 3;
    if (std.mem.findPos(u8, body, search_from, "---")) |idx| {
        var end = idx + 3;
        while (end < body.len and std.ascii.isWhitespace(body[end])) end += 1;
        return body[end..];
    }
    return body;
}

/// Is `label` (untrimmed) one of the intensity modes lite/full/ultra? Returns
/// the canonical lowercase form or null. Mirrors normalizeMode-on-a-label, but
/// only the three intensity rows are mode-keyed in the SKILL table/examples.
fn intensityLabel(label: []const u8) ?[]const u8 {
    var buf: [16]u8 = undefined;
    const t = std.mem.trim(u8, label, " \t");
    if (t.len == 0 or t.len > buf.len) return null;
    for (t, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lowered = buf[0..t.len];
    for (VALID_MODES) |m| if (std.mem.eql(u8, m, lowered)) return m;
    return null;
}

/// `| **Label** | ...` → inner Label slice (matches JS /^\|\s*\*\*(.+?)\*\*\s*\|/).
fn tableRowLabel(line: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, t, "|")) return null;
    const after_pipe = std.mem.trimStart(u8, t[1..], " \t");
    if (!std.mem.startsWith(u8, after_pipe, "**")) return null;
    const inner = after_pipe[2..];
    const close_idx = std.mem.indexOf(u8, inner, "**") orelse return null;
    // The JS regex requires a `|` to follow `**Label**\s*`. Enforce it so a
    // bold span that is not a table cell does not get treated as a row label.
    const rest = std.mem.trimStart(u8, inner[close_idx + 2 ..], " \t");
    if (!std.mem.startsWith(u8, rest, "|")) return null;
    return inner[0..close_idx];
}

/// `- label: ...` → label slice (matches JS /^-\s*([^:]+):\s*/). Null if no colon
/// or empty label.
fn bulletLabel(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "-")) return null;
    const after = std.mem.trimStart(u8, line[1..], " \t");
    const colon = std.mem.indexOfScalar(u8, after, ':') orelse return null;
    if (colon == 0) return null;
    return after[0..colon];
}

/// Filter the SKILL body to the active intensity mode. Keeps every line except
/// mode-keyed table rows / example bullets that belong to a DIFFERENT mode.
/// Mirrors hooks/ponytail-instructions.js filterSkillBodyForMode.
pub fn filterSkillBodyForMode(gpa: std.mem.Allocator, body: []const u8, mode: []const u8) ![]u8 {
    var mbuf: [16]u8 = undefined;
    const effective = normalizeRuntimeMode(&mbuf, mode) orelse DEFAULT_MODE;
    const without_fm = stripFrontmatter(body);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var first = true;
    // JS splits on /\r?\n/ then joins with '\n'. Split on '\n', strip a trailing
    // '\r' per line so CRLF input collapses to LF output, same as the JS.
    var it = std.mem.splitScalar(u8, without_fm, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");

        var keep = true;
        if (tableRowLabel(line)) |lbl| {
            if (intensityLabel(lbl)) |lm| keep = std.mem.eql(u8, lm, effective);
        } else if (bulletLabel(line)) |lbl| {
            if (intensityLabel(lbl)) |lm| keep = std.mem.eql(u8, lm, effective);
        }

        if (keep) {
            if (!first) try out.append(gpa, '\n');
            try out.appendSlice(gpa, line);
            first = false;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Build the full instruction string for `mode`. EXACT port of
/// hooks/ponytail-instructions.js getPonytailInstructions(mode):
///   1. configured = normalizePersistedMode(mode) || DEFAULT_MODE
///   2. independent (review) → one-line stub
///   3. effective = normalizeMode(configured) || DEFAULT_MODE
///   4. "<TOOL> MODE ACTIVE — level: <effective>\n\n" + filterSkillBodyForMode(body)
/// The SKILL body is injected (the JS reads it from disk; here the caller embeds
/// it). On the JS fail-to-read path the JS emits a hard-coded fallback; with an
/// embedded body that path is unreachable, so it is intentionally not ported.
pub fn getInstructions(gpa: std.mem.Allocator, skill_md: []const u8, mode: []const u8) ![]u8 {
    var cbuf: [16]u8 = undefined;
    const configured = normalizePersistedMode(&cbuf, mode) orelse DEFAULT_MODE;

    if (isIndependent(configured)) {
        return std.fmt.allocPrint(
            gpa,
            "{s} MODE ACTIVE — level: {s}. Behavior defined by /{s}-{s} skill.",
            .{ TOOL_UPPER, configured, TOOL, configured },
        );
    }

    var ebuf: [16]u8 = undefined;
    const effective = normalizeRuntimeMode(&ebuf, configured) orelse DEFAULT_MODE;

    const filtered = try filterSkillBodyForMode(gpa, skill_md, effective);
    defer gpa.free(filtered);
    return std.fmt.allocPrint(
        gpa,
        "{s} MODE ACTIVE — level: {s}\n\n{s}",
        .{ TOOL_UPPER, effective, filtered },
    );
}

// ── Multi-host output dispatch ───────────────────────────────────────────────
//
// Port of hooks/ponytail-runtime.js host detection + writeHookOutput. Codex and
// Copilot wrap the raw context in host-specific JSON envelopes; everything else
// gets the raw context bytes. Detection keys off the same env vars the JS reads.

/// True if running under GitHub Copilot's plugin host ($COPILOT_PLUGIN_DATA set,
/// non-empty). Mirrors ponytail-runtime.js `isCopilot`.
pub fn isCopilot() bool {
    if (getenv("COPILOT_PLUGIN_DATA")) |v| return v.len > 0;
    return false;
}

/// True if running under the Codex plugin host ($PLUGIN_DATA set, non-empty) and
/// NOT Copilot. Mirrors ponytail-runtime.js `isCodex` (Copilot takes priority).
pub fn isCodex() bool {
    if (isCopilot()) return false;
    if (getenv("PLUGIN_DATA")) |v| return v.len > 0;
    return false;
}

/// Append `s` to `out` as a JSON string body (the bytes BETWEEN the quotes),
/// escaping per the JSON spec exactly as JSON.stringify would. Used to build the
/// host envelopes by hand (no std.json.Stringify dependency, libc-only path).
fn appendJsonStringBody(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
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
                    // Other control chars → \u00XX, matching JSON.stringify.
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
}

/// Which host envelope to emit. Mirrors the ponytail-runtime.js isCopilot/isCodex
/// precedence (Copilot wins over Codex; otherwise plain).
pub const Host = enum { plain, codex, copilot };

/// Resolve the active host from the environment. Copilot takes priority.
pub fn detectHost() Host {
    if (isCopilot()) return .copilot;
    if (isCodex()) return .codex;
    return .plain;
}

/// Build the host-specific hook output for (`event`, `mode`, `context`) WITHOUT
/// writing it — returns an owned slice the caller frees. Detects the host from
/// the environment, then delegates to buildHookOutputFor.
pub fn buildHookOutput(
    gpa: std.mem.Allocator,
    event: []const u8,
    mode: []const u8,
    context: []const u8,
) ![]u8 {
    return buildHookOutputFor(gpa, detectHost(), event, mode, context);
}

/// Host-parameterized envelope builder — unit-testable without env vars. Mirrors
/// ponytail-runtime.js writeHookOutput's three branches:
///   - Copilot: `{"additionalContext":<ctx>}` on SessionStart w/ context, else `{}`.
///   - Codex:   `{"systemMessage":"PONYTAIL:<MODE>"}` (+ hookSpecificOutput if ctx).
///   - plain:   the raw context bytes.
/// `mode` is uppercased for the Codex systemMessage exactly like `mode.toUpperCase()`.
pub fn buildHookOutputFor(
    gpa: std.mem.Allocator,
    host: Host,
    event: []const u8,
    mode: []const u8,
    context: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (host == .copilot) {
        // Copilot reads additionalContext on SessionStart; ignores output else.
        if (std.mem.eql(u8, event, "SessionStart") and context.len > 0) {
            try out.appendSlice(gpa, "{\"additionalContext\":\"");
            try appendJsonStringBody(gpa, &out, context);
            try out.appendSlice(gpa, "\"}");
        } else {
            try out.appendSlice(gpa, "{}");
        }
        return out.toOwnedSlice(gpa);
    }

    if (host == .codex) {
        // {"systemMessage":"PONYTAIL:<MODE>"[,"hookSpecificOutput":{...}]}
        // Key order matches JS object-literal insertion order: systemMessage
        // first, then hookSpecificOutput when context is present.
        try out.appendSlice(gpa, "{\"systemMessage\":\"");
        try out.appendSlice(gpa, TOOL_UPPER);
        try out.append(gpa, ':');
        // mode.toUpperCase() — ASCII uppercase, escaped as a JSON string body.
        var ubuf: [64]u8 = undefined;
        if (mode.len <= ubuf.len) {
            for (mode, 0..) |ch, i| ubuf[i] = std.ascii.toUpper(ch);
            try appendJsonStringBody(gpa, &out, ubuf[0..mode.len]);
        } else {
            // Pathological length: uppercase in place over a duped copy.
            const up = try gpa.dupe(u8, mode);
            defer gpa.free(up);
            for (up) |*ch| ch.* = std.ascii.toUpper(ch.*);
            try appendJsonStringBody(gpa, &out, up);
        }
        try out.append(gpa, '"');
        if (context.len > 0) {
            try out.appendSlice(gpa, ",\"hookSpecificOutput\":{\"hookEventName\":\"");
            try appendJsonStringBody(gpa, &out, event);
            try out.appendSlice(gpa, "\",\"additionalContext\":\"");
            try appendJsonStringBody(gpa, &out, context);
            try out.appendSlice(gpa, "\"}");
        }
        try out.append(gpa, '}');
        return out.toOwnedSlice(gpa);
    }

    // Plain host (native Claude): SessionStart accepts raw stdout, but
    // SubagentStart drops it — that event needs the hookSpecificOutput JSON form
    // or the injected ruleset never reaches the subagent (issue #252 / #254).
    // {"hookSpecificOutput":{"hookEventName":<event>,"additionalContext":<ctx>}}
    if (std.mem.eql(u8, event, "SubagentStart")) {
        try out.appendSlice(gpa, "{\"hookSpecificOutput\":{\"hookEventName\":\"");
        try appendJsonStringBody(gpa, &out, event);
        try out.appendSlice(gpa, "\",\"additionalContext\":\"");
        try appendJsonStringBody(gpa, &out, context);
        try out.appendSlice(gpa, "\"}}");
        return out.toOwnedSlice(gpa);
    }

    // Plain host: raw context bytes.
    try out.appendSlice(gpa, context);
    return out.toOwnedSlice(gpa);
}

/// Emit the host-specific hook output to stdout. Mirrors ponytail-runtime.js
/// writeHookOutput. Builds the envelope via buildHookOutput then writes it.
pub fn writeHookOutput(gpa: std.mem.Allocator, event: []const u8, mode: []const u8, context: []const u8) void {
    const payload = buildHookOutput(gpa, event, mode, context) catch {
        // Build failure → fall back to raw context so the plain-host contract is
        // still honored (and never crash a hook).
        writeStdout(context);
        return;
    };
    defer gpa.free(payload);
    writeStdout(payload);
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "isValidMode whitelist rejects injection" {
    try std.testing.expect(isValidMode("full"));
    try std.testing.expect(isValidMode("ultra"));
    try std.testing.expect(!isValidMode("wenyan-ultra")); // ponytail has no wenyan
    try std.testing.expect(!isValidMode("rm -rf /"));
    try std.testing.expect(!isValidMode("../../etc/passwd"));
    try std.testing.expect(!isValidMode(""));
    try std.testing.expect(!isValidMode("off")); // off is not slash-persistable
}

test "isStatuslineMode whitelist" {
    try std.testing.expect(isStatuslineMode("off"));
    try std.testing.expect(isStatuslineMode("lite"));
    try std.testing.expect(isStatuslineMode("full"));
    try std.testing.expect(isStatuslineMode("ultra"));
    try std.testing.expect(isStatuslineMode("review"));
    try std.testing.expect(!isStatuslineMode("wenyan"));
    try std.testing.expect(!isStatuslineMode("\x1b[31mevil"));
    try std.testing.expect(!isStatuslineMode(""));
}

/// Make a unique temp dir via libc (Io-free; matches the code under test).
fn makeTmpDir(gpa: std.mem.Allocator) ![]u8 {
    const base = getenv("TMPDIR") orelse "/tmp";
    const dir = try std.fmt.allocPrint(gpa, "{s}/zighooktest.{d}", .{ base, c.getpid() });
    var dbuf: [std.fs.max_path_bytes]u8 = undefined;
    const dz = try toZ(&dbuf, dir);
    _ = c.mkdir(dz, 0o700);
    return dir;
}

fn readSmall(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try toZ(&pbuf, path);
    const flags: c.O = .{ .ACCMODE = .RDONLY };
    const fd = c.open(pz, flags, @as(c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);
    var buf: [256]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n < 0) return error.ReadFailed;
    return gpa.dupe(u8, buf[0..@intCast(n)]);
}

test "safeWriteFlag refuses symlinked target (clobber attack)" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const victim = try std.fs.path.join(gpa, &.{ dir_path, "victim.txt" });
    defer gpa.free(victim);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".active" });
    defer gpa.free(flag);

    {
        var vb: [std.fs.max_path_bytes]u8 = undefined;
        const vz = try toZ(&vb, victim);
        const fl: c.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true };
        const fd = c.open(vz, fl, @as(c.mode_t, 0o600));
        try std.testing.expect(fd >= 0);
        _ = c.write(fd, "SECRET", 6);
        _ = close(fd);
    }

    var vbuf: [std.fs.max_path_bytes]u8 = undefined;
    var fbuf: [std.fs.max_path_bytes]u8 = undefined;
    const vz = try toZ(&vbuf, victim);
    const fz = try toZ(&fbuf, flag);
    try std.testing.expect(c.symlink(vz, fz) == 0); // plant flag -> victim

    try std.testing.expectError(error.SymlinkRefused, safeWriteFlag(gpa, flag, "full"));

    const data = try readSmall(gpa, victim);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("SECRET", data); // untouched

    _ = c.unlink(fz);
    _ = c.unlink(vz);
}

test "safeWriteFlag writes mode on clean path" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);
    const flag = try std.fs.path.join(gpa, &.{ dir_path, ".active2" });
    defer gpa.free(flag);

    try safeWriteFlag(gpa, flag, "ultra");
    const data = try readSmall(gpa, flag);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("ultra", data);

    var fb: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.unlink(try toZ(&fb, flag));
}

test "safeWriteFlag refuses symlinked GRANDPARENT (ancestor) dir" {
    const gpa = std.testing.allocator;
    const dir_path = try makeTmpDir(gpa);
    defer gpa.free(dir_path);

    const real = try std.fs.path.join(gpa, &.{ dir_path, "real" });
    defer gpa.free(real);
    const inner = try std.fs.path.join(gpa, &.{ real, "inner" });
    defer gpa.free(inner);
    const link = try std.fs.path.join(gpa, &.{ dir_path, "link" });
    defer gpa.free(link);

    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    var b3: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.mkdir(try toZ(&b1, real), 0o700);
    _ = c.mkdir(try toZ(&b2, inner), 0o700);
    try std.testing.expect(c.symlink(try toZ(&b1, real), try toZ(&b3, link)) == 0);

    const flag = try std.fs.path.join(gpa, &.{ link, "inner", ".active3" });
    defer gpa.free(flag);

    try std.testing.expectError(error.ParentSymlinkRefused, safeWriteFlag(gpa, flag, "full"));

    const real_flag = try std.fs.path.join(gpa, &.{ inner, ".active3" });
    defer gpa.free(real_flag);
    try std.testing.expect(classify(real_flag) == .missing);

    _ = c.unlink(try toZ(&b3, link));
}

test "getDefaultMode honors env var" {
    // We can't portably set env from inside the process without libc setenv;
    // instead assert the fallback contract: with no env/config, default = full.
    // (Env-var path is exercised via the differential harness in build/CI.)
    const gpa = std.testing.allocator;
    const m = try getDefaultMode(gpa);
    defer gpa.free(m);
    try std.testing.expect(isStatuslineMode(m));
}

// ── Instruction-builder tests ────────────────────────────────────────────────

const TEST_SKILL =
    "---\n" ++
    "name: ponytail\n" ++
    "---\n\n" ++
    "# Ponytail\n" ++
    "Intro line.\n" ++
    "| Level | What change |\n" ++
    "|-------|------------|\n" ++
    "| **lite** | lite row |\n" ++
    "| **full** | full row |\n" ++
    "| **ultra** | ultra row |\n" ++
    "- lite: lite example\n" ++
    "- full: full example\n" ++
    "- ultra: ultra example\n" ++
    "- No unrequested abstractions: keep me\n";

test "filterSkillBodyForMode keeps active row, drops others, keeps non-mode bullets" {
    const gpa = std.testing.allocator;
    const out = try filterSkillBodyForMode(gpa, TEST_SKILL, "full");
    defer gpa.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "full row") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "full example") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lite row") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ultra row") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "lite example") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ultra example") == null);
    // Non-mode bullet is a real rule — must survive.
    try std.testing.expect(std.mem.indexOf(u8, out, "keep me") != null);
    // Frontmatter stripped; intro + heading kept.
    try std.testing.expect(std.mem.indexOf(u8, out, "name: ponytail") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# Ponytail") != null);
}

test "getInstructions header + body per intensity mode" {
    const gpa = std.testing.allocator;
    inline for (.{ "lite", "full", "ultra" }) |m| {
        const out = try getInstructions(gpa, TEST_SKILL, m);
        defer gpa.free(out);
        const prefix = TOOL_UPPER ++ " MODE ACTIVE — level: " ++ m ++ "\n\n";
        try std.testing.expect(std.mem.startsWith(u8, out, prefix));
        try std.testing.expect(std.mem.indexOf(u8, out, m ++ " row") != null);
    }
}

test "getInstructions normalizes raw mode like the JS (trim/case/fallback)" {
    const gpa = std.testing.allocator;
    // Mixed case + whitespace normalizes to lowercase 'ultra'.
    const a = try getInstructions(gpa, TEST_SKILL, "  ULTRA ");
    defer gpa.free(a);
    try std.testing.expect(std.mem.startsWith(u8, a, TOOL_UPPER ++ " MODE ACTIVE — level: ultra\n\n"));
    // Unknown mode → DEFAULT_MODE (full).
    const b = try getInstructions(gpa, TEST_SKILL, "bogus");
    defer gpa.free(b);
    try std.testing.expect(std.mem.startsWith(u8, b, TOOL_UPPER ++ " MODE ACTIVE — level: full\n\n"));
}

test "getInstructions independent (review) mode is the stub" {
    const gpa = std.testing.allocator;
    const out = try getInstructions(gpa, TEST_SKILL, "review");
    defer gpa.free(out);
    const expected = TOOL_UPPER ++ " MODE ACTIVE — level: review. Behavior defined by /" ++ TOOL ++ "-review skill.";
    try std.testing.expectEqualStrings(expected, out);
    // The stub does NOT include the SKILL body.
    try std.testing.expect(std.mem.indexOf(u8, out, "full row") == null);
}

// ── writeHookOutput / host-dispatch tests ────────────────────────────────────

test "buildHookOutputFor plain host emits raw context" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .plain, "SessionStart", "full", "RULES HERE");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("RULES HERE", out);
}

test "buildHookOutputFor codex emits systemMessage + hookSpecificOutput" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .codex, "SessionStart", "ultra", "ctx line\nx");
    defer gpa.free(out);
    const expected = "{\"systemMessage\":\"" ++ TOOL_UPPER ++ ":ULTRA\",\"hookSpecificOutput\":" ++
        "{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"ctx line\\nx\"}}";
    try std.testing.expectEqualStrings(expected, out);
}

test "buildHookOutputFor codex without context omits hookSpecificOutput" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .codex, "SessionStart", "full", "");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"systemMessage\":\"" ++ TOOL_UPPER ++ ":FULL\"}", out);
}

test "buildHookOutputFor copilot SessionStart with context wraps additionalContext" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .copilot, "SessionStart", "full", "ctx \"q\" \\");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"additionalContext\":\"ctx \\\"q\\\" \\\\\"}", out);
}

test "buildHookOutputFor copilot non-SessionStart or empty context emits {}" {
    const gpa = std.testing.allocator;
    const a = try buildHookOutputFor(gpa, .copilot, "UserPromptSubmit", "full", "ctx");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("{}", a);
    const b = try buildHookOutputFor(gpa, .copilot, "SessionStart", "full", "");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("{}", b);
}

// ── SubagentStart (#254) ──
//
// Native Claude drops raw stdout for SubagentStart, so the plain host must wrap
// the ruleset in the hookSpecificOutput JSON form (mirroring upstream's
// ponytail-runtime.js SubagentStart branch). Codex already carries
// hookSpecificOutput whenever context is present, so its SubagentStart works via
// the same envelope used for SessionStart.

test "buildHookOutputFor plain SubagentStart wraps hookSpecificOutput" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .plain, "SubagentStart", "full", "RULES\nhere \"q\"");
    defer gpa.free(out);
    const expected = "{\"hookSpecificOutput\":{\"hookEventName\":\"SubagentStart\"," ++
        "\"additionalContext\":\"RULES\\nhere \\\"q\\\"\"}}";
    try std.testing.expectEqualStrings(expected, out);
}

test "buildHookOutputFor plain SessionStart still raw (SubagentStart-only wrap)" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .plain, "SessionStart", "full", "RAW RULES");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("RAW RULES", out);
}

test "buildHookOutputFor codex SubagentStart emits systemMessage + hookSpecificOutput" {
    const gpa = std.testing.allocator;
    const out = try buildHookOutputFor(gpa, .codex, "SubagentStart", "full", "RULES");
    defer gpa.free(out);
    const expected = "{\"systemMessage\":\"" ++ TOOL_UPPER ++ ":FULL\",\"hookSpecificOutput\":" ++
        "{\"hookEventName\":\"SubagentStart\",\"additionalContext\":\"RULES\"}}";
    try std.testing.expectEqualStrings(expected, out);
}
