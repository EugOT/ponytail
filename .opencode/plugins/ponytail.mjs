// ponytail — OpenCode plugin (THIN ESM SHIM).
//
// OpenCode mandates an ESM plugin module here — this file cannot be pure Zig.
// But its LOGIC is not: the ruleset body is built by the Zig `ponytail-instructions`
// binary (zig/src/instructions.zig, sharing common.getInstructions with the
// SessionStart activate hook and the MCP server). This shim keeps ONLY the
// opencode lifecycle glue (config / system.transform / command.execute.before)
// and routes the real work through that binary via hooks/ponytail-instructions-bin.js.
// If the binary is absent it transparently falls back to the JS builder, so the
// opencode contract never breaks (correctness over purity).
//
// OpenCode loads this as a server plugin — add it to your opencode.json:
//   { "plugin": ["./.opencode/plugins/ponytail.mjs"] }

import { createRequire } from 'module';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// The shared modules are CommonJS; bridge to them from this ES module.
const require = createRequire(import.meta.url);
// Ruleset body comes from the Zig binary (JS fallback inside the bridge).
const { buildInstructions } = require('../../hooks/ponytail-instructions-bin');
const { getDefaultMode, normalizePersistedMode } = require('../../hooks/ponytail-config');
const { safeWriteFlag } = require('../../hooks/ponytail-fs-safe');

// OpenCode has no flag-file convention of its own; keep mode beside its config.
const statePath = path.join(
  process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config'),
  'opencode',
  '.ponytail-active',
);

function readMode() {
  try {
    return normalizePersistedMode(fs.readFileSync(statePath, 'utf8').trim()) || getDefaultMode();
  } catch (e) {
    return getDefaultMode();
  }
}

function writeMode(mode) {
  // Symlink-safe atomic write — refuses a pre-planted symlink at statePath or
  // its parent rather than clobbering whatever it points at.
  safeWriteFlag(statePath, mode);
}

export default async ({ client } = {}) => {
  const log = (level, message) => {
    try { client && client.app && client.app.log({ body: { service: 'ponytail', level, message } }); } catch (e) {}
  };

  const ponytailSkillsDir = path.resolve(__dirname, '../../skills');

  return {
    // Register skills directory so opencode discovers ponytail skills.
    config: async (config) => {
      config.skills = config.skills || {};
      config.skills.paths = config.skills.paths || [];
      if (!config.skills.paths.includes(ponytailSkillsDir)) {
        config.skills.paths.push(ponytailSkillsDir);
      }
    },

    // Append the ruleset to the system prompt every turn. The body is built by
    // the Zig ponytail-instructions binary (JS fallback inside buildInstructions).
    'experimental.chat.system.transform': async (_input, output) => {
      const mode = readMode();
      if (mode === 'off') return;
      output.system.push(buildInstructions(mode));
    },

    // Persist `/ponytail <level>` so the next turn's injection follows it.
    // ponytail: mode applies from the next message, not the current one — the
    // transform reads the flag the command writes. Good enough; switch to a
    // synchronous store if same-turn switching ever matters.
    'command.execute.before': async (input) => {
      if (!input || input.command !== 'ponytail') return;
      // `off` is persisted like any mode; the transform reads it and stays silent.
      const mode = normalizePersistedMode((input.arguments || '').trim()) || getDefaultMode();
      writeMode(mode);
      log('info', 'ponytail ' + mode);
    },
  };
};
