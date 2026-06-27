# ponytail-launch.ps1 — Windows/PowerShell sibling of bin/ponytail-launch.
#
# The Claude Code plugin (.claude-plugin/plugin.json → hooks/claude-codex-hooks.json)
# runs the lifecycle hooks through a launcher so it never bundles per-platform
# blobs. On POSIX that launcher is the bash bin/ponytail-launch; PowerShell can't
# run a bash script, so this is the Windows entry point the `commandWindows` hook
# field invokes. It resolves an already-installed ponytail-* binary (standalone
# install → local dev build → cache), forwarding stdin and args.
#
# Usage:  ponytail-launch.ps1 <binary-name> [args...]   (stdin is forwarded)
#   e.g.  ponytail-launch.ps1 ponytail-activate
#         ponytail-launch.ps1 ponytail-hook
#
# Resolution order (mirrors the bash launcher):
#   1. $env:CLAUDE_CONFIG_DIR\hooks\<name>(.exe)   (standalone install)
#   2. <repo-root>\zig\zig-out\bin\<name>(.exe)    (local clone / dev build)
#   3. $PONYTAIL_CACHE\<name>(.exe)                (previously downloaded)
#
# Windows native Zig binaries are still pending (R6-Windows): the cross-compile in
# .github/workflows/release-binaries.yml ships macOS + Linux only. Until a Windows
# archive ships there is no step-4 download here — if no binary resolves, this exits
# 0 (silent no-op) so a missing Windows binary never blocks SessionStart / prompt
# submission, exactly like the POSIX hooks' silent-fail contract.

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$Name,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Rest
)

$ErrorActionPreference = "Stop"

# Try to run $exe (with the .exe sibling on Windows) forwarding stdin + $Rest. On
# success the script exits with the child's exit code; otherwise returns to let the
# next resolution step run.
function Try-Run([string]$exe) {
  foreach ($cand in @($exe, "$exe.exe")) {
    if (Test-Path -LiteralPath $cand -PathType Leaf) {
      & $cand @Rest
      exit $LASTEXITCODE
    }
  }
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1. standalone-installed hooks dir
$cfg = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
Try-Run (Join-Path (Join-Path $cfg "hooks") $Name)

# 2. local clone / dev build (launcher lives at bin\, zig\ is a sibling at repo root)
Try-Run (Join-Path (Join-Path (Join-Path (Join-Path (Split-Path -Parent $here) "zig") "zig-out") "bin") $Name)

# 3. previously downloaded cache
$cache = if ($env:PONYTAIL_CACHE) {
  $env:PONYTAIL_CACHE
} elseif ($env:XDG_CACHE_HOME) {
  Join-Path (Join-Path $env:XDG_CACHE_HOME "ponytail") "bin"
} else {
  Join-Path (Join-Path (Join-Path $HOME ".cache") "ponytail") "bin"
}
Try-Run (Join-Path $cache $Name)

# ponytail: no-binary no-op branch (R6-Windows ceiling).
#   Known ceiling: no Windows archive ships yet (the release workflow builds macOS
#     + Linux only), so resolution steps 1-3 can all miss on a fresh Windows box.
#   Behavior: silent no-op (exit 0) so a missing Windows binary never blocks
#     SessionStart / prompt submission — matches the POSIX hooks' silent-fail.
#   Upgrade path (R6-Windows): once the workflow ships a Windows ponytail binary,
#     add a step-4 download/verify branch here mirroring bin/ponytail-launch.
exit 0
