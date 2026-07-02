#!/bin/bash
# grove installer. Resolves a release on grove-code/downloads, downloads the
# single per-platform bundle (ERTS embedded) + the bootstrap `grove` CLI, and
# hands off to `grove up` for the versioned-dir install and the atomic `current`
# symlink flip (see docs/updates.md). All install/flip logic lives in the Rust
# binary and is unit-tested; this script only does the GitHub-Releases fetch,
# then stages it into the local-dir source `grove up` already understands (the
# same path the install smoke test exercises).
#
# Usage:
#   curl -fsSL https://grove-code.dev/install.sh | bash
#   curl -fsSL https://grove-code.dev/install.sh | channel=canary bash   # prereleases
#   curl -fsSL https://grove-code.dev/install.sh | bash -s v0.1.0
#
# Environment:
#   channel      release channel: stable (default), canary
#   GROVE_HOME   data dir (default: ~/.grove)
#
# Records the resolved channel in $GROVE_HOME/channel so later `grove up` (no
# --channel / GROVE_CHANNEL) keeps following it.
set -euo pipefail

repo="grove-code/downloads"
grove_home="${GROVE_HOME:-$HOME/.grove}"
channel="${channel:-stable}"
version="${1:-}"

die() { echo "grove: $1" >&2; exit 1; }

# Accept-Encoding: identity defeats corp MITM proxies that recompress gzip
# mid-flight (re-compression changes bytes → sha256 mismatch). Matches the
# legacy installer's hardening.
fetch() { curl -fsSL -H "Accept-Encoding: identity" "$1" -o "$2"; }
fetch_text() { curl -fsSL -H "Accept-Encoding: identity" "$1"; }

# Platform string, matching grove's host_target(): <arch>-<os>.
case "$(uname -m)" in
  arm64 | aarch64) arch=aarch64 ;;
  x86_64 | amd64) arch=x86_64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac
target="${arch}-${os}"

# The release no longer builds Intel macOS (no macos-13 runners) — reject it up
# front with a clear "unsupported platform" rather than letting the fetch below
# fail with a misleading asset-unreachable error on a tag that never had it.
case "$target" in
  x86_64-darwin) die "unsupported platform: $target (Intel macOS is not built; use an Apple Silicon mac)" ;;
esac

# Resolve the release tag for the channel (unless a version was pinned). canary
# is a prerelease tag suffix (v<semver>-canary.N); stable is the latest release.
if [ -z "$version" ]; then
  if [ "$channel" = "stable" ]; then
    tag=$(curl -fsSI -H "Accept-Encoding: identity" \
      "https://github.com/${repo}/releases/latest" |
      grep -i '^location:' | sed -E 's|.*/tag/([^[:space:]]+).*|\1|')
    [ -n "$tag" ] || die "could not resolve the latest stable release"
  else
    tag=$(fetch_text "https://api.github.com/repos/${repo}/releases" |
      grep -oE '"tag_name": "v[^"]+-'"${channel}"'\.[0-9]+"' |
      sed -E 's/.*"(v[^"]+)".*/\1/' |
      sort -t. -k1,1V -k2,2V -k3,3V -k4,4n | tail -1)
    [ -n "$tag" ] || die "no ${channel} releases found on ${repo}"
  fi
else
  # A pinned arg may be given with or without the leading v.
  case "$version" in v*) tag="$version" ;; *) tag="v$version" ;; esac
fi
vsn="${tag#v}" # the version names versions/<vsn> + must match the bundle's reported version

base="https://github.com/${repo}/releases/download/${tag}"
echo "grove: installing ${vsn} (${target}) from ${repo}"

# Stage the bundle as a local-dir source: grove up reads <base>/<vsn>/<target>.tar.gz
# (+ .sha256), so lay it out exactly that way and point GROVE_INSTALL_BASE_URL at it.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stage="$tmp/stage"
mkdir -p "$stage/$vsn"

fetch "$base/$target.tar.gz" "$stage/$vsn/$target.tar.gz" \
  || die "release asset unreachable: $target.tar.gz (no v1 bundle on $tag?)"
fetch "$base/$target.tar.gz.sha256" "$stage/$vsn/$target.tar.gz.sha256" \
  || die "release asset unreachable: $target.tar.gz.sha256"
fetch "$base/grove-$target" "$tmp/grove" \
  || die "bootstrap CLI unreachable: grove-$target"
chmod +x "$tmp/grove"

# Hand off: the bootstrap CLI does the versioned-dir install + atomic flip,
# verifying the checksum sidecar we just staged. No server is running on a clean
# machine, so this only lays versions/<vsn> and flips current.
GROVE_HOME="$grove_home" GROVE_INSTALL_BASE_URL="$stage" "$tmp/grove" up --version "$vsn"

# Persist the channel this box follows so `grove up` (no --channel/GROVE_CHANNEL)
# keeps pulling from it. Derive it from the *resolved tag*, not $channel: a pinned
# `bash -s v0.1.1-canary.2` runs with channel=stable (the default) but is really a
# canary box — keying off $channel would strand it on stable. A prerelease suffix
# (-<channel>.N) ⇒ that channel; a bare semver ⇒ stable.
case "$vsn" in
  *-*.[0-9]*) resolved_channel="${vsn##*-}"; resolved_channel="${resolved_channel%.*}" ;;
  *) resolved_channel="stable" ;;
esac
printf '%s\n' "$resolved_channel" >"$grove_home/channel"

# Put `grove` on PATH via a stable symlink → current/bin/grove. A running process
# keeps its mapped binary, so future flips never disturb it.
grove_bin="$grove_home/current/bin/grove"
linked=""
for d in /usr/local/bin "$HOME/.local/bin"; do
  if [ -d "$d" ] && [ -w "$d" ]; then
    ln -sf "$grove_bin" "$d/grove"
    linked="$d"
    break
  fi
done
if [ -z "$linked" ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sf "$grove_bin" "$HOME/.local/bin/grove"
  linked="$HOME/.local/bin"
  echo "grove: $linked is not on your PATH — add it to use \`grove\` directly"
fi

echo "grove: linked → $linked/grove"
echo "grove: done. Run 'grove on' to start the server."
