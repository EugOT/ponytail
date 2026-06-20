# ponytail Zig hooks

A native rewrite of the ponytail glue scripts in Zig 0.16. Three binaries from
one source tree, sharing `src/common.zig`:

| Binary | Replaces | Role |
|--------|----------|------|
| `ponytail-hook` | `hooks/ponytail-mode-tracker.js` | UserPromptSubmit — parse `/ponytail <level>`, persist mode, emit reinforcement |
| `ponytail-activate` | `hooks/ponytail-activate.js` | SessionStart — resolve default mode, write flag, emit ruleset, statusline nudge |
| `ponytail-statusline` | `hooks/ponytail-statusline.sh` / `.ps1` | statusline badge — read flag, whitelist mode, print colored `[PONYTAIL]` |

**37/37 unit tests pass** (common 6, hook 8, activate 12, statusline 11),
including a symlink-clobber attack that is *refused by construction* and a
control-byte-smuggling attempt that is *stripped and whitelisted out*.

## What they do

### `ponytail-hook` (UserPromptSubmit)

Read the hook JSON event on stdin, detect a `/ponytail <level>` slash command,
persist the mode through a **symlink-safe** flag write, and emit the
`hookSpecificOutput` JSON the harness injects back as per-turn reinforcement.

```console
$ printf '{"prompt":"/ponytail ultra"}' | ponytail-hook
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"ponytail mode active: ultra"}}
```

### `ponytail-activate` (SessionStart)

Resolve the default mode (`PONYTAIL_DEFAULT_MODE` env → `config.json` →
`full`), write the flag (symlink-safe), and emit the ponytail ruleset as stdout
— Claude Code injects SessionStart stdout as hidden system context. The ruleset
is the tool's `SKILL.md`, embedded at comptime and filtered to the active
intensity, mirroring `hooks/ponytail-instructions.js`. `off` mode clears the
flag and prints `OK`. If `settings.json` has no `statusLine`, a setup nudge is
appended.

```console
$ printf '{}' | ponytail-activate | head -1
PONYTAIL MODE ACTIVE — level: full
```

### `ponytail-statusline`

Read the flag at `$CLAUDE_CONFIG_DIR/.ponytail-active` with `O_NOFOLLOW`,
whitelist the mode (`off|lite|full|ultra|review`), strip any control bytes, and
print the colored badge — no shell, cross-platform.

```console
$ printf 'ultra\n' > "$CLAUDE_CONFIG_DIR/.ponytail-active" && ponytail-statusline
[PONYTAIL:ULTRA]    # ANSI 256-color 108, like the .sh
```

All three are drop-in replacements for their Node/sh counterparts: same flag
location (`$CLAUDE_CONFIG_DIR/.ponytail-active`, or
`$HOME/.claude/.ponytail-active`), same stdout contracts. The one intentional
divergence is the activate statusline nudge, which names the installed
`ponytail-statusline` binary/script rather than splicing an absolute path the JS
resolves at runtime (a comptime binary has no install-dir knowledge). The
existing `ponytail-hook` keeps its JSON `hookSpecificOutput` contract, which
differs from the JS mode-tracker's `PONYTAIL MODE CHANGED` line — that predates
this phase.

## Why

- **Symlink-safe by construction.** The flag write opens a temp file with
  `O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW` at mode `0600`, then atomically
  `rename(2)`s it onto the target. Before that it walks ancestors below a
  trusted base and refuses if any are symlinks or non-directories, then `lstat`s
  the target itself. A local attacker who pre-plants a symlink at the predictable
  flag path or a parent directory cannot redirect the write onto, say,
  `~/.ssh/authorized_keys`. This is the same property the JS `safeWriteFlag` now
  enforces — but in Zig it is the only code path; there is no naive
  `writeFileSync` to regress to.
- **~196 KB static binary** (`ReleaseSmall`, libc-linked). No `node_modules`, no
  runtime to ship, no `npm install` in the install path.
- **~18 ms cold start.** No interpreter warm-up — the OS execs a small static
  binary and it is done. Every prompt submit pays this once; Node pays
  interpreter startup each time.

## Build

The default `-Dtool` in this repo is `ponytail`; pass `-Dtool=caveman` only
inside the caveman repo (the activate binary embeds `../skills/<tool>/SKILL.md`,
which must exist). One Zig codebase compiles all three binaries; the tool
identity is comptime-selected, so the slash command (`/ponytail`), flag filename
(`.ponytail-active`), and emitted context strings are baked in at build time.

```sh
cd zig
zig build                                  # → zig-out/bin/{ponytail-hook,ponytail-activate,ponytail-statusline}
zig build -Doptimize=ReleaseSmall          # small release binaries
zig build test --summary all               # 37/37 unit tests
```

`-Dtool` is validated at configure time — a typo (`-Dtool=bogus`) is rejected
before any compile. Requires Zig `0.16.0` or newer (`minimum_zig_version` in
`build.zig.zon`). Build artifacts (`zig/.zig-cache/`, `zig/zig-out/`) are
gitignored — the binaries are built, not committed.

## Tests

37 tests across four targets, all inline:

- `src/common.zig` — `isValidMode` / `isStatuslineMode` whitelists reject
  injection; `safeWriteFlag` refuses a symlinked target, refuses a symlinked
  grandparent ancestor, and round-trips a mode on a clean path; `getDefaultMode`
  fallback contract.
- `src/main.zig` (hook) — `parseSlashMode` (exact `/ponytail` token, garbage
  rejected, no wenyan), `extractPrompt` via `std.json`.
- `src/activate.zig` — frontmatter stripping, intensity-label recognition,
  table-row / bullet label extraction, `filterSkillBodyForMode` (keeps the
  active mode's rows, drops other modes', keeps non-mode rule bullets), the
  instruction header, and the independent (review) stub.
- `src/statusline.zig` — badge rendering (bare vs `:MODE`), the whitelist
  rejecting junk, control-byte stripping, the tri-state read (missing →
  nothing, empty/junk → bare badge, valid → `:MODE`), and `O_NOFOLLOW` refusing
  a symlinked flag.

## Differential parity

Validated against the JS/sh originals on identical inputs:

- **statusline** — byte-identical across `ultra/full/lite/review/off`, junk
  (whitelist-blanked), missing flag (no output), and empty file (bare badge).
- **activate** — the emitted ruleset body is byte-identical across
  `full/lite/ultra/review`; `off` prints `OK` and clears the flag in both; the
  nudge is suppressed identically when `settings.json` has a `statusLine`; the
  written flag bytes match. The only divergence is the nudge's trailing path
  reference (intentional — see above).

## Status

Written against the stable libc C ABI (`std.c` plus a couple of `extern` decls)
rather than the in-flight `std.Io` surface — a hook binary links libc anyway,
and this pins it to a stable interface. A future rewrite can migrate to
`std.Io` once 0.16 stabilizes; the security logic is identical.
