#!/bin/sh
# grove uninstaller (v1 versioned-dir layout). Stops the server, removes the
# `grove` symlink from PATH, and deletes the data dir. Mirrored to
# grove-code/scripts (served at grove-code.dev/uninstall.sh) by mirror-scripts.yml.
#
# Usage:
#   curl -fsSL https://grove-code.dev/uninstall.sh | sh
#   GROVE_HOME=/custom sh uninstall.sh
#
# Environment:
#   GROVE_HOME   data dir (default: ~/.grove)
set -eu

GROVE_HOME="${GROVE_HOME:-$HOME/.grove}"

# Stop a running server via the installed binary (best-effort).
if [ -x "$GROVE_HOME/current/bin/grove" ]; then
  GROVE_HOME="$GROVE_HOME" "$GROVE_HOME/current/bin/grove" off >/dev/null 2>&1 || true
fi

# Remove the PATH symlink wherever install.sh may have placed it. Only unlink a
# symlink that actually points into GROVE_HOME — never a user's unrelated binary.
for d in /usr/local/bin "$HOME/.local/bin"; do
  link="$d/grove"
  if [ -L "$link" ]; then
    target=$(readlink "$link")
    case "$target" in
    "$GROVE_HOME"/*) rm -f "$link" && echo "grove: unlinked $link" ;;
    esac
  fi
done

# Remove the data dir (versions, current/previous symlinks, manifest, worktrees).
rm -rf "$GROVE_HOME"
echo "grove: removed $GROVE_HOME"
echo "grove: done."
