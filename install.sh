#!/usr/bin/env bash
# ponytail — installer shim (pure-Zig runtime).
#
# Downloads the prebuilt ponytail Zig binaries for your platform from the latest
# GitHub Release, SHA-256-verifies the archive, deploys the Claude Code hook
# binaries into ~/.claude/hooks, and wires SessionStart + UserPromptSubmit +
# statusline into ~/.claude/settings.json. No Node, no Zig toolchain required.
#
# Unlike caveman, ponytail's `zig build` produces NO dedicated `-install` binary —
# ponytail ships as a plugin (marketplace + lifecycle hooks) and the Zig binaries
# are the RUNTIME (hook / activate / statusline / mcp / instructions). So this
# script resolves those runtime binaries and performs the settings.json wiring
# itself, in pure shell, rather than exec'ing an installer binary.
#
# One-line install:
#   curl -fsSL https://raw.githubusercontent.com/EugOT/ponytail/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/EugOT/ponytail/main/install.sh | bash -s -- --force
#
# Local clone:
#   bash install.sh [flags]      # builds from source if `zig` is present,
#                                # otherwise downloads the release binaries
#
# Flags:
#   --force   re-install over an existing install
#   --dry-run print what would happen, change nothing
#
# Windows: the Zig binaries don't yet cross-compile to Windows and the JS hooks
# have been retired, so there is no standalone Windows install path yet — install
# via the plugin marketplace instead (see install.ps1). macOS/Linux only here.

set -euo pipefail

REPO="EugOT/ponytail"
BIN_PREFIX="ponytail"

# The six runtime binaries `zig build` produces (no `-install`, no `*-claw`):
#   ponytail-hook         UserPromptSubmit mode tracker
#   ponytail-activate     SessionStart ruleset injector
#   ponytail-subagent     SubagentStart ruleset injector (#254)
#   ponytail-statusline   statusline badge
#   ponytail-mcp          stdio MCP server
#   ponytail-instructions one-shot ruleset print (opencode/pi exec bridge)
ALL_BINS=(ponytail-hook ponytail-activate ponytail-subagent ponytail-statusline ponytail-mcp ponytail-instructions)

# Deployed into ~/.claude/hooks so the launcher's step-1 resolution finds them.
# activate/hook/statusline are also wired into settings.json by wire_settings_fresh;
# subagent (SubagentStart, #254) is launched only by the plugin manifest
# (hooks/claude-codex-hooks.json), so it is deployed here but NOT settings-wired.
# The MCP and instructions binaries are runtime exec targets used by other surfaces,
# not Claude Code hooks, so they are NOT deployed into the hooks dir by this shim.
HOOK_BINS=(ponytail-hook ponytail-activate ponytail-subagent ponytail-statusline)

err() { echo "ponytail: $*" >&2; }

# Emit a JSON string literal whose VALUE is the given path single-quoted for the
# shell, so a path containing spaces survives Claude Code's shell-parse of the
# "command" field. Single-quotes inside the path are escaped the POSIX way
# ('\''), then the whole shell-quoted form is JSON-escaped (backslash + quote).
# Output includes the surrounding JSON double-quotes, e.g.:
#   /a b/x  ->  "'/a b/x'"
_json_squote() {
  local s="$1"
  # POSIX shell single-quote: close quote, escaped quote, reopen quote.
  s="'${s//\'/\'\\\'\'}'"
  # JSON-escape for embedding in a double-quoted JSON string.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# ── flags ────────────────────────────────────────────────────────────────────
FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force|-f)   FORCE=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

# ── platform detection → release asset name ──────────────────────────────────
detect_platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) err "unsupported OS '$os'. Windows: use install.ps1."; exit 1 ;;
  esac
  case "$arch" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=x64 ;;
    *) err "unsupported arch '$arch'."; exit 1 ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

# ── checksum helper (sha256sum on Linux, shasum on macOS) ────────────────────
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum  >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else err "no sha256sum/shasum available — cannot verify download."; exit 1; fi
}

# True iff every runtime binary exists+executable in $1.
_bins_present() {
  local d="$1" b
  [ -n "$d" ] || return 1
  for b in "${ALL_BINS[@]}"; do
    [ -x "$d/$b" ] || return 1
  done
  return 0
}

# ── resolve a directory holding the ponytail-* binaries ──────────────────────
# Strategy:
#   1. local clone with prebuilt binaries at zig/zig-out/bin → use as-is
#   2. local clone with `zig` on PATH → build, then use zig/zig-out/bin
#   3. otherwise → download the per-platform release archive + SHA-256 verify
# Echoes the resolved binary directory on stdout. May set BIN_TMP (caller cleans).
BIN_TMP=""
resolve_bin_dir() {
  local script_dir repo_root out_bin
  script_dir=""
  # BASH_SOURCE is unset under `curl | bash`; tolerate it.
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || script_dir=""
  fi
  if [ -n "$script_dir" ]; then
    repo_root="$script_dir"
    out_bin="$repo_root/zig/zig-out/bin"
    # (1) already-built clone.
    if _bins_present "$out_bin"; then
      echo "$out_bin"; return 0
    fi
    # (2) clone + zig toolchain → build from source.
    if [ -f "$repo_root/zig/build.zig" ] && command -v zig >/dev/null 2>&1; then
      err "building runtime binaries from source (zig build) …"
      ( cd "$repo_root/zig" && zig build -Dtool=ponytail -Doptimize=ReleaseSafe ) >&2 \
        || { err "zig build failed."; exit 1; }
      if _bins_present "$out_bin"; then echo "$out_bin"; return 0; fi
    fi
  fi
  # (3) download the release archive.
  _download_release_bin_dir
}

_download_release_bin_dir() {
  command -v curl >/dev/null 2>&1 || { err "curl required to download release binaries."; exit 1; }
  command -v tar  >/dev/null 2>&1 || { err "tar required to unpack release binaries.";  exit 1; }
  local plat archive base
  plat="$(detect_platform)"
  archive="$BIN_PREFIX-$plat.tar.gz"
  base="https://github.com/$REPO/releases/latest/download"
  BIN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ponytail-install.XXXXXX")"
  err "downloading $archive …"
  curl -fsSL "$base/$archive"        -o "$BIN_TMP/$archive"        || { err "download failed ($archive). No release for $plat yet?"; exit 1; }
  curl -fsSL "$base/$archive.sha256" -o "$BIN_TMP/$archive.sha256" || { err "checksum download failed."; exit 1; }
  local want got
  want="$(awk '{print $1}' "$BIN_TMP/$archive.sha256")"
  got="$(sha256_of "$BIN_TMP/$archive")"
  if [ "$want" != "$got" ]; then
    err "SHA-256 mismatch — refusing to install. expected $want got $got"; exit 1
  fi
  err "checksum OK"
  tar -C "$BIN_TMP" -xzf "$BIN_TMP/$archive" || { err "archive extraction failed ($archive)."; exit 1; }
  chmod +x "$BIN_TMP"/$BIN_PREFIX-* 2>/dev/null || true
  if ! _bins_present "$BIN_TMP"; then
    err "release archive missing required binaries — bad release for $plat."; exit 1
  fi
  echo "$BIN_TMP"
}

# ── symlink-safe deploy of one file ──────────────────────────────────────────
# Refuse to write through a symlink at the destination (or its immediate parent)
# so a local attacker can't redirect the predictable hook path to clobber another
# file. Mirrors the symlink policy in zig/src/common.zig safeWriteFlag: write the
# tmp INSIDE the destination's real parent dir, re-validate dst+parent are not
# symlinks immediately before the final placement, then atomically rename.
#
# The earlier version checked dst/parent once, then cp'd + mv -f'd later — leaving
# a TOCTOU window where an attacker could swap the parent (or dst) to a symlink
# between the check and the move. We close it by (a) resolving the parent's real
# path up front, (b) staging the tmp in that real dir, and (c) re-checking dst and
# parent for symlinks in the same breath as the rename, refusing on any change.
safe_install_file() {
  local src="$1" dst="$2" mode="$3"

  local name; name="$(basename "$dst")"
  local parent; parent="$(dirname "$dst")"

  # First, refuse on the PREDICTABLE (un-resolved) paths — mirrors safeWriteFlag's
  # isSymlink(path)/ancestorUnsafe(dir) checks. Without this, `cd "$parent"` below
  # would silently FOLLOW a symlinked hooks dir to its (real, non-symlink) target
  # and happily install there. So if the literal destination, or its literal
  # parent, is a symlink an attacker could have planted, refuse outright.
  if [ -L "$dst" ]; then
    err "refusing to overwrite symlink: $dst"; return 1
  fi
  if [ -L "$parent" ]; then
    err "refusing to install under symlinked dir: $parent"; return 1
  fi

  # Resolve the parent to its real path and operate on THAT, so a later swap of a
  # path component can't redirect us (the staged tmp + rename both live in the
  # resolved dir). The hooks dir was just created by the caller (mkdir -p).
  local real_parent
  real_parent="$(cd "$parent" 2>/dev/null && pwd -P)" || {
    err "cannot resolve hooks dir: $parent"; return 1
  }
  if [ -L "$real_parent" ]; then
    err "refusing to install under symlinked dir: $real_parent"; return 1
  fi
  local real_dst="$real_parent/$name"
  if [ -L "$real_dst" ]; then
    err "refusing to overwrite symlink: $real_dst"; return 1
  fi

  # Stage the tmp in the SAME real dir as the destination so the final rename is
  # atomic (same filesystem) and never crosses into an attacker-chosen directory.
  local tmp
  tmp="$(mktemp "$real_parent/.${name}.XXXXXX")" || {
    err "failed to stage temp file in $real_parent"; return 1
  }
  # shellcheck disable=SC2064
  trap 'rm -f "$tmp"' RETURN
  cp "$src" "$tmp" || { err "failed to copy $src"; return 1; }
  chmod "$mode" "$tmp" || { err "failed to chmod $tmp"; return 1; }

  # Last-moment revalidation: refuse if dst or its real parent became a symlink
  # since the checks above (close the TOCTOU window before we commit the rename).
  if [ -L "$real_parent" ] || [ ! -d "$real_parent" ]; then
    err "hooks dir changed under us (symlink/not-a-dir): $real_parent"; return 1
  fi
  if [ -L "$real_dst" ]; then
    err "destination became a symlink: $real_dst"; return 1
  fi
  # Atomic, no-clobber-of-symlink placement: rename within the validated real dir.
  mv -f "$tmp" "$real_dst" || { err "failed to place $real_dst"; return 1; }
  trap - RETURN
}

# ── settings.json wiring (pure shell, no node) ───────────────────────────────
# ponytail: pure-shell settings-writer (no JSON parser) — known ceiling.
#   Known ceiling: ponytail has no settings-merge binary, so we only WRITE a fresh
#     settings.json (absent/empty). We refuse to edit a pre-existing, non-ponytail
#     settings.json in place — a regex/sed merge without a real JSON parser risks
#     corrupting JSONC (comments) or clobbering the user's other hooks.
#   Upgrade path: add a tiny Zig settings-merge binary (the caveman caveman-settings
#     equivalent) and call it here so existing settings.json can be merged safely.
# Idempotency check happens in already_installed(); this only runs on fresh wire.
wire_settings_fresh() {
  # Claude Code passes each "command" string to a shell, so an unquoted hooks-dir
  # path with spaces (e.g. ~/Library/Application Support/...) would shell-split and
  # the hook would fail to launch. Single-quote each command path inside the JSON
  # string value — consistent with the plugin manifests, which quote the launcher.
  local activate_bin hook_bin statusline_bin
  activate_bin="$(_json_squote "$HOOKS_DIR/ponytail-activate")"
  hook_bin="$(_json_squote "$HOOKS_DIR/ponytail-hook")"
  statusline_bin="$(_json_squote "$HOOKS_DIR/ponytail-statusline")"
  cat > "$SETTINGS" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          { "type": "command", "command": $activate_bin, "timeout": 5 }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          { "type": "command", "command": $hook_bin, "timeout": 5 }
        ]
      }
    ]
  },
  "statusLine": { "type": "command", "command": $statusline_bin }
}
EOF
}

# ── idempotency probe ────────────────────────────────────────────────────────
# ponytail: idempotency probe — known ceiling.
#   Already installed iff every hook binary is present in $HOOKS_DIR AND
#   settings.json references the managed hooks. A substring scan suffices.
#   Known ceiling: this is a substring scan, not a JSON-aware check — it can't tell
#     a live hook entry from the same string buried in a comment. Good enough to
#     gate re-install; not a structural validation.
#   Upgrade path: replace the greps with the settings-merge binary's own probe once
#     that binary exists (see wire_settings_fresh ceiling note).
already_installed() {
  local b
  for b in "${HOOK_BINS[@]}"; do
    [ -x "$HOOKS_DIR/$b" ] || return 1
  done
  [ -f "$SETTINGS" ] || return 1
  grep -q 'ponytail-activate'   "$SETTINGS" 2>/dev/null || return 1
  grep -q 'ponytail-hook'       "$SETTINGS" 2>/dev/null || return 1
  grep -q 'ponytail-statusline' "$SETTINGS" 2>/dev/null || return 1
  return 0
}

main() {
  local bin_dir
  bin_dir="$(resolve_bin_dir)"
  trap '[ -n "$BIN_TMP" ] && rm -rf "$BIN_TMP"' EXIT

  if [ "$FORCE" -eq 0 ] && already_installed; then
    echo "ponytail hooks already installed in $HOOKS_DIR"
    echo "  Re-run with --force to overwrite: bash install.sh --force"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] resolved binary dir: $bin_dir"
    echo "[dry-run] would deploy into $HOOKS_DIR:"
    local b
    for b in "${HOOK_BINS[@]}"; do echo "    $b"; done
    echo "[dry-run] would wire SessionStart + UserPromptSubmit + statusline into $SETTINGS"
    return 0
  fi

  # 1. Ensure hooks dir exists.
  mkdir -p "$HOOKS_DIR"

  # 2. Deploy each hook binary (symlink-safe, 0755).
  local b
  for b in "${HOOK_BINS[@]}"; do
    safe_install_file "$bin_dir/$b" "$HOOKS_DIR/$b" 0755 \
      || { err "failed to install $b"; exit 1; }
    echo "  Installed: $HOOKS_DIR/$b"
  done

  # 3. Wire hooks + statusline into settings.json.
  if [ ! -s "$SETTINGS" ]; then
    wire_settings_fresh
    echo "  Hooks wired in $SETTINGS"
  elif already_installed; then
    echo "  settings.json already references ponytail hooks — left untouched."
  else
    err "$SETTINGS exists and isn't ponytail-wired."
    err "       Refusing to edit it without a JSON parser. Add by hand:"
    err "         SessionStart  → command: $HOOKS_DIR/ponytail-activate"
    err "         UserPromptSubmit → command: $HOOKS_DIR/ponytail-hook"
    err "         statusLine    → command: $HOOKS_DIR/ponytail-statusline"
    err "       Or install via the plugin marketplace, which wires this for you."
    # wire_settings_fresh did NOT run, so the install is incomplete. Fail here
    # instead of falling through to "Done!/What's installed" — never report
    # success when the statusline/hooks aren't actually wired into settings.json.
    err "Install incomplete: settings.json was not wired. Hooks are deployed but inactive."
    return 1
  fi

  echo ""
  echo "Done! Restart Claude Code to activate."
  echo ""
  echo "What's installed:"
  echo "  - SessionStart hook (ponytail-activate): auto-loads ponytail rules every session"
  echo "  - Mode tracker hook (ponytail-hook): updates statusline when you switch modes"
  echo "    (/ponytail lite, /ponytail ultra, /ponytail-review, etc.)"
  echo "  - Statusline badge (ponytail-statusline): shows [PONYTAIL] or [PONYTAIL:ULTRA] etc."
}

main
