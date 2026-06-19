const fs = require('fs');
const path = require('path');
const { getClaudeDir } = require('./ponytail-config');
const { safeWriteFlag } = require('./ponytail-fs-safe');

const STATE_FILE = '.ponytail-active';
const isCopilot = Boolean(process.env.COPILOT_PLUGIN_DATA);
const isCodex = !isCopilot && Boolean(process.env.PLUGIN_DATA);

// $PLUGIN_DATA / $COPILOT_PLUGIN_DATA come from the host harness's environment.
// Reject any value containing a `..` path segment so a poisoned env can't walk
// the state file out of its intended directory before path.join resolves it.
// Fall back to the Claude dir on rejection rather than honoring the traversal.
function safeStateDir(dir, fallback) {
  if (typeof dir !== 'string' || dir.length === 0) return fallback;
  const segments = dir.split(/[\\/]+/);
  if (segments.includes('..')) return fallback;
  return dir;
}

let stateDir = getClaudeDir();
if (isCodex) stateDir = safeStateDir(process.env.PLUGIN_DATA, stateDir);
if (isCopilot) stateDir = safeStateDir(process.env.COPILOT_PLUGIN_DATA, stateDir);

const statePath = path.join(stateDir, STATE_FILE);

function setMode(mode) {
  // Symlink-safe atomic write — refuses if statePath or its parent is a symlink
  // a local attacker pre-planted to redirect the write. Silent-fails otherwise.
  safeWriteFlag(statePath, mode);
}

function clearMode() {
  try { fs.unlinkSync(statePath); } catch (e) {}
}

function writeHookOutput(event, mode, context = '') {
  if (isCopilot) {
    // Copilot reads additionalContext on SessionStart; ignores output elsewhere.
    process.stdout.write(JSON.stringify(
      event === 'SessionStart' && context ? { additionalContext: context } : {}));
    return;
  }
  if (isCodex) {
    const output = { systemMessage: `PONYTAIL:${mode.toUpperCase()}` };
    if (context) {
      output.hookSpecificOutput = {
        hookEventName: event,
        additionalContext: context,
      };
    }
    process.stdout.write(JSON.stringify(output));
    return;
  }
  process.stdout.write(context);
}

module.exports = {
  clearMode,
  isCodex,
  isCopilot,
  setMode,
  writeHookOutput,
};
