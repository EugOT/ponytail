#!/usr/bin/env bash
# CLAUDE_CONFIG_DIR overrides ~/.claude, matching where the hooks write the flag (issue #34)
flag="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.ponytail-active"
[ -f "$flag" ] || exit 0

mode=$(head -n1 "$flag" | tr -d '[:space:]')

# Whitelist-validate before echoing into the badge: a clobbered/symlinked flag
# could otherwise smuggle arbitrary bytes (escape sequences, control chars) onto
# the terminal. Anything not in the known set is blanked.
case "$mode" in
    off|lite|full|ultra|review) ;;
    *) mode="" ;;
esac

if [ -z "$mode" ] || [ "$mode" = "full" ]; then
    printf '\033[38;5;108m[PONYTAIL]\033[0m'
else
    printf '\033[38;5;108m[PONYTAIL:%s]\033[0m' "$(printf '%s' "$mode" | tr '[:lower:]' '[:upper:]')"
fi
