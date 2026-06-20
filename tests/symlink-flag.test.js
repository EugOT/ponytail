#!/usr/bin/env node
// Tests for hooks/ponytail-fs-safe.js safeWriteFlag — the symlink-clobber
// defense behind setMode / writeDefaultMode / the opencode plugin.
//
// Run: node --test tests/symlink-flag.test.js
// Mirrors caveman's tests/test_symlink_flag.js.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { safeWriteFlag } = require('../hooks/ponytail-fs-safe');

function mkTmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'ponytail-symlink-'));
}

test('refuses a symlinked target, leaving the victim file intact', (t) => {
  const tmp = mkTmp();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  // Victim holds a secret the attacker wants clobbered.
  const victim = path.join(tmp, 'victim.txt');
  fs.writeFileSync(victim, 'SECRET', { mode: 0o600 });

  // Attacker pre-plants a symlink at the predictable flag path -> victim.
  const flag = path.join(tmp, '.ponytail-active');
  fs.symlinkSync(victim, flag);

  const ok = safeWriteFlag(flag, 'full');

  assert.strictEqual(ok, false, 'safeWriteFlag must refuse a symlinked target');
  assert.strictEqual(
    fs.readFileSync(victim, 'utf8'),
    'SECRET',
    'victim file must be untouched'
  );
  // The symlink itself still points at the victim, never resolved/written.
  assert.strictEqual(fs.lstatSync(flag).isSymbolicLink(), true);
});

test('refuses when the parent directory is a symlink', (t) => {
  const tmp = mkTmp();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const realDir = path.join(tmp, 'real');
  fs.mkdirSync(realDir);
  const linkDir = path.join(tmp, 'link');
  fs.symlinkSync(realDir, linkDir);

  const ok = safeWriteFlag(path.join(linkDir, '.ponytail-active'), 'ultra');
  assert.strictEqual(ok, false, 'must refuse a symlinked parent directory');
  assert.strictEqual(
    fs.existsSync(path.join(realDir, '.ponytail-active')),
    false,
    'no flag should be written through the symlinked parent'
  );
});

test('refuses when a GRANDPARENT (ancestor) directory is a symlink', (t) => {
  const tmp = mkTmp();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  // realRoot/inner is the genuine tree; an attacker symlinks a grandparent.
  const realRoot = path.join(tmp, 'real');
  fs.mkdirSync(path.join(realRoot, 'inner'), { recursive: true });
  const linkRoot = path.join(tmp, 'link'); // link -> real (the grandparent)
  fs.symlinkSync(realRoot, linkRoot);

  // Target two levels under the symlinked ancestor: link/inner/.ponytail-active.
  const flag = path.join(linkRoot, 'inner', '.ponytail-active');
  const ok = safeWriteFlag(flag, 'ultra');

  assert.strictEqual(ok, false, 'must refuse a symlinked ancestor, not just the immediate parent');
  assert.strictEqual(
    fs.existsSync(path.join(realRoot, 'inner', '.ponytail-active')),
    false,
    'no flag should be written through the symlinked ancestor'
  );
});

test('writes mode at 0600 on a clean path', (t) => {
  const tmp = mkTmp();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const flag = path.join(tmp, 'nested', '.ponytail-active');
  const ok = safeWriteFlag(flag, 'ultra');

  assert.strictEqual(ok, true, 'clean write should succeed');
  assert.strictEqual(fs.readFileSync(flag, 'utf8'), 'ultra');

  if (process.platform !== 'win32') {
    const mode = fs.statSync(flag).mode & 0o777;
    assert.strictEqual(mode, 0o600, `expected 0600, got 0${mode.toString(8)}`);
  }
});

test('overwrites an existing regular flag file atomically', (t) => {
  const tmp = mkTmp();
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const flag = path.join(tmp, '.ponytail-active');
  assert.strictEqual(safeWriteFlag(flag, 'lite'), true);
  assert.strictEqual(fs.readFileSync(flag, 'utf8'), 'lite');

  assert.strictEqual(safeWriteFlag(flag, 'ultra'), true);
  assert.strictEqual(fs.readFileSync(flag, 'utf8'), 'ultra');

  // No leftover temp files in the directory.
  const stragglers = fs.readdirSync(tmp).filter((f) => f.endsWith('.tmp'));
  assert.deepStrictEqual(stragglers, [], 'temp file must be renamed away');
});
