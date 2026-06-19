# ponytail Zig hook

A native rewrite of the `UserPromptSubmit` hook in Zig 0.16. Proven PoC:
**6/6 unit tests pass**, including a symlink-clobber attack that is *refused by
construction*.

## What it does

Same job as the Node hook (`hooks/ponytail-runtime.js` +
`hooks/ponytail-config.js`): read the hook JSON event on stdin, detect a
`/ponytail <level>` slash command, persist the mode through a **symlink-safe**
flag write, and emit the `hookSpecificOutput` JSON the harness injects back as
per-turn reinforcement.

```console
$ printf '{"prompt":"/ponytail ultra"}' | ponytail-hook
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"ponytail mode active: ultra"}}
```

It is a drop-in replacement for the Node hook: same stdin contract, same stdout
contract, same flag-file location (`$CLAUDE_CONFIG_DIR/.ponytail-active`, or
`$HOME/.claude/.ponytail-active`).

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

Built with `-Dtool=ponytail`. One Zig codebase compiles both this and the
caveman hook; the tool identity is comptime-selected from the `-Dtool` option,
so the slash command (`/ponytail`), flag filename (`.ponytail-active`), and
emitted context string are all baked in at build time.

```sh
cd zig
zig build -Dtool=ponytail                       # debug binary → zig-out/bin/ponytail-hook
zig build -Dtool=ponytail -Doptimize=ReleaseSmall   # ~196 KB release binary
zig build test -Dtool=ponytail --summary all    # 6/6 unit tests
```

Requires Zig `0.16.0` or newer (`minimum_zig_version` in `build.zig.zon`). Build
artifacts (`zig/.zig-cache/`, `zig/zig-out/`) are gitignored — the hook is built,
not committed.

## Tests

`src/main.zig` carries its unit tests inline:

- `isValidMode` — whitelist rejects injection (`rm -rf /`, `../../etc/passwd`).
- `parseSlashMode` — exact `/ponytail` token, `/ponytail ultra`, garbage rejected (ponytail modes: lite/full/ultra; no wenyan).
- `extractPrompt` — pulls the `prompt` field from the hook JSON via `std.json`.
- `safeWriteFlag refuses symlinked target (clobber attack)` — plants a symlink
  at the flag path pointing at a victim file holding `SECRET`, asserts the write
  is refused (`error.SymlinkRefused`) and the victim is untouched.
- `safeWriteFlag writes mode on clean path` — round-trips a mode through a clean
  path.
- `safeWriteFlag refuses symlinked GRANDPARENT (ancestor) dir` — plants a
  symlinked ancestor and asserts nothing is written through it.

## Status

This is a proof of concept that validates the security core and the
stdin/stdout contract. It is written against the stable libc C ABI (`std.c` plus
a couple of `extern` decls) rather than the in-flight `std.Io` surface — a hook
binary links libc anyway, and this pins the PoC to a stable interface. A
production rewrite can migrate to `std.Io` once 0.16 stabilizes; the security
logic is identical.
