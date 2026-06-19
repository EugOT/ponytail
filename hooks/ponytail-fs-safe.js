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
//   - refuses if the immediate parent directory is a symlink
//   - writes to a temp file opened with O_CREAT|O_EXCL|O_WRONLY (+ O_NOFOLLOW
//     where the platform exposes it) at mode 0600
//   - atomically renames the temp file onto the target
//
// Silent-fails on every filesystem error — the flag/config is best-effort and a
// write failure must never throw into a hook and block a session.

'use strict';

const fs = require('fs');
const path = require('path');

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

// Symlink-safe, atomic flag/config write.
//
// Returns true on success, false on any refusal or filesystem error. Never
// throws — hooks call this on the critical session-start path.
function safeWriteFlag(flagPath, content) {
  try {
    const target = path.resolve(flagPath);
    const dir = path.dirname(target);

    // Create the parent dir if missing. mkdir on an existing symlinked dir does
    // not turn it into a real dir, so the symlink check below still fires.
    try {
      fs.mkdirSync(dir, { recursive: true });
    } catch (e) {
      // best-effort; the open below will fail loudly enough (and we swallow it)
    }

    // Refuse a symlinked parent directory (clobber redirect via the dir).
    if (isSymlink(dir)) return false;

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
