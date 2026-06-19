// ponytail — exec bridge to the Zig `ponytail-instructions` binary.
//
// The host-mandated ESM/JS entry shims (opencode .mjs, pi index.js) cannot be
// pure Zig — opencode loads an ESM module, pi loads a JS module. But the RULESET
// LOGIC they need (build the mode-filtered instruction body) now lives in Zig,
// in the `ponytail-instructions` binary (zig/src/instructions.zig), which shares
// common.getInstructions with the SessionStart activate hook and the MCP server.
//
// This module is the thin bridge: it spawns that binary with the mode in
// $PONYTAIL_INSTRUCTIONS_MODE and returns its stdout — byte-identical to what
// hooks/ponytail-instructions.js getPonytailInstructions(mode) returns.
//
// Correctness over purity: if the Zig binary is not found or fails for any
// reason, we fall back to the JS builder (ponytail-instructions.js). The
// opencode/pi integration contract therefore NEVER breaks — a missing binary
// degrades to the exact same behavior as before this shim existed.

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { getPonytailInstructions } = require('./ponytail-instructions');

// Candidate locations for the built binary, in priority order:
//   1. $PONYTAIL_INSTRUCTIONS_BIN explicit override
//   2. zig/zig-out/bin/ponytail-instructions (local build, repo root is ../)
//   3. bin/ponytail-instructions next to this repo's bin shims (install layout)
//   4. ponytail-instructions on $PATH (resolved by execFileSync via shell:false →
//      only if an absolute/relative path; PATH lookup handled separately below)
function candidateBins() {
  const repoRoot = path.resolve(__dirname, '..');
  const list = [];
  if (process.env.PONYTAIL_INSTRUCTIONS_BIN) {
    list.push(process.env.PONYTAIL_INSTRUCTIONS_BIN);
  }
  list.push(path.join(repoRoot, 'zig', 'zig-out', 'bin', 'ponytail-instructions'));
  list.push(path.join(repoRoot, 'bin', 'ponytail-instructions'));
  return list;
}

function resolveBin() {
  for (const candidate of candidateBins()) {
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch (e) {
      // ignore and keep probing
    }
  }
  return null;
}

// Build the ruleset for `mode`. Routes through the Zig binary when present,
// falls back to the JS builder otherwise. ALWAYS returns the same string the JS
// builder would — the Zig binary is a byte-identical port (verified by the
// differential test), so callers cannot tell which path produced the result.
//
// Note on "off": the Zig binary prints NOTHING for "off" (the shims inject
// nothing in that case). The JS builder returns a full body for "off"; the
// shims already special-case "off" BEFORE calling this, so that divergence is
// never observable. We still guard here: if the binary returns empty for a
// non-off mode (should never happen), fall back to JS rather than inject blank.
function buildInstructions(mode) {
  const bin = resolveBin();
  if (bin) {
    try {
      const out = execFileSync(bin, [], {
        env: { ...process.env, PONYTAIL_INSTRUCTIONS_MODE: String(mode) },
        encoding: 'utf8',
        maxBuffer: 1024 * 1024,
      });
      if (out && out.length > 0) return out;
      // Empty stdout for a non-off mode is unexpected → fall through to JS.
    } catch (e) {
      // Binary missing/unexecutable/crashed → fall through to JS.
    }
  }
  return getPonytailInstructions(mode);
}

module.exports = { buildInstructions, resolveBin };
