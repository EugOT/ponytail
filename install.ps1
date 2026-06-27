# ponytail — installer shim (Windows / PowerShell).
#
# ponytail is now a pure-Zig runtime: the SessionStart / UserPromptSubmit /
# statusline hooks are native Zig binaries (no Node, no JS hooks). Those binaries
# do NOT yet cross-compile to Windows (R6-Windows: stdio/subprocess/argv libc →
# std.Io is still pending), and the JS hooks they replaced have been retired.
#
# So there is no standalone Windows install path right now. On Windows, install
# ponytail via the plugin marketplace instead — the plugin wires the lifecycle
# hooks through bin/ponytail-launch, which resolves a native binary for your
# platform and will pick up Windows binaries automatically once R6-Windows ships.
#
# macOS / Linux users get the pure-Zig binaries via install.sh.

[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Pony([string]$msg) { Write-Host "ponytail: $msg" }

Write-Pony "No standalone Windows installer yet (pure-Zig runtime; Windows binaries pending — R6-Windows)."
Write-Pony ""
Write-Pony "Install ponytail on Windows via the plugin marketplace, which wires the"
Write-Pony "lifecycle hooks for you through bin/ponytail-launch (no Node required):"
Write-Pony "  /plugin marketplace add EugOT/ponytail"
Write-Pony "  /plugin install ponytail@ponytail"
Write-Pony ""
Write-Pony "macOS / Linux: run install.sh for the native Zig binaries."

# ponytail: Windows no-op installer (R6-Windows ceiling).
#   Known ceiling: the Zig runtime doesn't cross-compile to Windows yet, so there
#     is no standalone Windows install path; this shim accepts the install.sh flags
#     (-Force / -DryRun) for interface parity and exits 0 without installing.
#   Upgrade path (R6-Windows): once Windows binaries ship, replace this no-op with
#     the real download/verify/wire logic (the install.sh equivalent).
exit 0
