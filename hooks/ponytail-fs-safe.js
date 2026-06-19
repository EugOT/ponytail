// ponytail — symlink-safe filesystem helper for flag/config writes.
//
// The predictable state/config paths ponytail writes (`.ponytail-active`,
// `config.json`) are a classic local symlink-clobber vector: an attacker with
// write access to the parent directory can pre-plant a symlink at the path so a
// naive `fs.writeFileSync` follows it and overwrites an arbitrary file the user
// owns (e.g. ~/.ssh/authorized_keys, a shell rc).
//
// safeWriteFlag closes that hole:
//   - refuses if the target path is itself a symlink
//   - refuses if any ancestor directory below a trusted base is a symlink
//   - writes to a temp file opened with O_CREAT|O_EXCL|O_WRONLY (+ O_NOFOLLOW
//     where the platform exposes it) at mode 0600
//   - atomically renames the temp file onto the target
//
// Silent-fails on every filesystem error — the flag/config is best-effort and a
// write failure must never throw into a hook and block a session.

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

// lstatSync that maps ENOENT to null and rethrows nothing — callers only need
// "is this a symlink right now".
function lstatOrNull(p) {
  try {
    return fs.lstatSync(p);
  } catch (e) {
    return null;
  }
}

// True if `p` exists AND is a symlink. A missing path is not a symlink.
function isSymlink(p) {
  const st = lstatOrNull(p);
  return Boolean(st && st.isSymbolicLink());
}

// Trusted base directories. The flag/config target must live under one of
// these. We resolve each with realpath ONCE, which collapses benign system
// symlinks (e.g. macOS /var -> /private/var) above the user-writable area, then
// lstat-walk only the tail. CLAUDE_CONFIG_DIR / XDG_CONFIG_HOME let callers add
// their own roots; tmpdir is included so tests (and any tmp-based flag) work.
function trustedBases() {
  const bases = [os.homedir(), os.tmpdir()];
  if (process.env.CLAUDE_CONFIG_DIR) bases.push(process.env.CLAUDE_CONFIG_DIR);
  if (process.env.XDG_CONFIG_HOME) bases.push(process.env.XDG_CONFIG_HOME);
  if (process.env.PONYTAIL_STATE_BASE) bases.push(process.env.PONYTAIL_STATE_BASE);
  return bases.filter(Boolean);
}

// True if reaching directory `dir` would pass through a symlink an attacker
// could have planted at ANY level below a trusted base — not just the immediate
// parent. Checking only the immediate parent (the old behavior) misses a
// symlinked grandparent, which redirects the eventual open/rename just the same.
//
// Algorithm: pick the longest existing trusted base that is a lexical prefix of
// `dir`, resolve it with realpath (this absorbs benign system symlinks ABOVE the
// base so they are never judged), then lstat each remaining tail component built
// on that real anchor. Any symlinked (or non-directory) tail component => unsafe.
// A not-yet-existing tail is fine — mkdir will create real directories there.
function isAnyAncestorSymlink(dir) {
  const resolved = path.resolve(dir);

  let base = null;
  let anchor = null;
  for (const b of trustedBases()) {
    const rb = path.resolve(b);
    if (resolved === rb || resolved.startsWith(rb + path.sep)) {
      let real;
      try {
        real = fs.realpathSync(rb);
      } catch (e) {
        continue;
      }
      if (!base || rb.length > base.length) {
        base = rb;
        anchor = real;
      }
    }
  }
  // Outside every trusted base — refuse rather than walk from filesystem root
  // (where system symlinks would either false-positive or be un-judgeable).
  if (!base) return true;

  const tail = path.relative(base, resolved).split(path.sep).filter(Boolean);
  let cur = anchor;
  for (const part of tail) {
    cur = path.join(cur, part);
    const st = lstatOrNull(cur);
    if (!st) break; // tail not created yet → mkdir makes real dirs; safe
    if (st.isSymbolicLink()) return true;
    if (!st.isDirectory()) return true;
  }
  return false;
}

// Symlink-safe, atomic flag/config write.
//
// Returns true on success, false on any refusal or filesystem error. Never
// throws — hooks call this on the critical session-start path.
function safeWriteFlag(flagPath, content) {
  try {
    const target = path.resolve(flagPath);
    const dir = path.dirname(target);

    // Refuse before mkdir so a symlinked/non-directory ancestor cannot redirect
    // recursive directory creation.
    if (isAnyAncestorSymlink(dir)) return false;

    // Create the parent dir if missing.
    try {
      // 0700 so the state/config parent is owner-only — matches the Zig hook's
      // mkdir(0o700) and limits who can race a symlink into the directory.
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    } catch (e) {
      // best-effort; the open below will fail loudly enough (and we swallow it)
    }

    // Re-check after mkdir so newly-created tails are still ordinary dirs.
    if (isAnyAncestorSymlink(dir)) return false;

    // Refuse a symlinked target file (the actual clobber vector).
    if (isSymlink(target)) return false;

    const tempPath = path.join(
      dir,
      `.${path.basename(target)}.${process.pid}.${Date.now()}.tmp`
    );

    // wx === O_CREAT | O_EXCL | O_WRONLY. Add O_NOFOLLOW where available so the
    // open itself refuses to follow a symlink planted between our check and the
    // open (TOCTOU defense at the temp path).
    const O_NOFOLLOW =
      typeof fs.constants.O_NOFOLLOW === 'number' ? fs.constants.O_NOFOLLOW : 0;
    const flags =
      fs.constants.O_WRONLY |
      fs.constants.O_CREAT |
      fs.constants.O_EXCL |
      O_NOFOLLOW;

    let fd;
    try {
      fd = fs.openSync(tempPath, flags, 0o600);
      fs.writeSync(fd, String(content));
      try {
        fs.fchmodSync(fd, 0o600);
      } catch (e) {
        // best-effort on platforms without fchmod (Windows)
      }
    } finally {
      if (fd !== undefined) {
        try {
          fs.closeSync(fd);
        } catch (e) {
          // ignore
        }
      }
    }

    try {
      fs.renameSync(tempPath, target);
    } catch (e) {
      try {
        fs.unlinkSync(tempPath);
      } catch (e2) {
        // ignore
      }
      return false;
    }

    return true;
  } catch (e) {
    // Silent-fail — flag/config write is best-effort, never block a session.
    return false;
  }
}

module.exports = { safeWriteFlag, isSymlink };
