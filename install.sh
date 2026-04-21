#!/bin/bash
set -euo pipefail

# grove installer (v3 -- three-artifact model)
# Usage: curl -fsSL .../install.sh | bash
#
# Installs CLI, Elixir release, and ERTS to ~/.grove
# Downloads in parallel. Skips ERTS on upgrade if version matches.
#
# Environment variables:
#   channel           - Release channel: stable (default), canary
#   GROVE_HOME        - Override installation root (default: ~/.grove)
#   grove_install_dir - Override CLI binary location (default: $GROVE_HOME/bin)
#
# Examples:
#   curl -fsSL .../install.sh | bash                    # Latest stable
#   curl -fsSL .../install.sh | channel=canary bash     # Latest canary
#   curl -fsSL .../install.sh | bash -s v0.1.0-canary.1 # Specific version

repo="grove-code/downloads"
grove_home="${GROVE_HOME:-$HOME/.grove}"
install_dir="${grove_install_dir:-$grove_home/bin}"
channel="${channel:-stable}"
version="${1:-}"

# ── colors + ui ─────────────────────────────────────────────
bold='\033[1m'
dim='\033[2m'
green='\033[0;32m'
white='\033[0;37m'
red='\033[0;31m'
nc='\033[0m'
cl='\033[K'

t=0.08

die() { echo -e "\n${red}error${nc}: $1" >&2; exit 1; }

ui_line() {
    local p="$1" pipe="$2" content="$3"
    echo -e "  ${p}${pipe}${nc}${content}${cl}"
}

ui_redraw() {
    local p="$1" l1="$2" l2="$3" l3="$4"
    # Restore to the cursor position saved by the skeleton (top of box).
    # Absolute anchor — safe under terminal scroll and stray newlines.
    echo -en "\033[u"
    ui_line "$p" "╭─" "  ${l1}"
    ui_line "$p" "│ " ""
    ui_line "$p" "│ " "  ${l2}"
    ui_line "$p" "│ " ""
    ui_line "$p" "╰─" "  ${l3}"
    echo -e "${cl}"
}

ui_bar_w() {
    local pct=$1 w=$2
    local f=$(( pct * w / 100 )) e=$(( w - pct * w / 100 ))
    printf "${white}"; for ((i=0;i<f;i++)); do printf '━'; done
    printf "${nc}${dim}"; for ((i=0;i<e;i++)); do printf '─'; done
    printf "${nc}"
}

ui_bar_g() {
    local pct=$1 w=$2
    local f=$(( pct * w / 100 )) e=$(( w - pct * w / 100 ))
    printf "${green}"; for ((i=0;i<f;i++)); do printf '━'; done
    printf "${nc}${white}"; for ((i=0;i<e;i++)); do printf '━'; done
    printf "${nc}"
}

# ── helpers ─────────────────────────────────────────────────
download() {
    if command -v curl &>/dev/null; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget &>/dev/null; then
        wget -qO "$2" "$1"
    else
        die "Neither curl nor wget found"
    fi
}

sha256_check() {
    local file="$1" expected="$2"
    [[ -z "$expected" ]] && return 0
    local actual
    if command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        return 0
    fi
    [[ "$actual" == "$expected" ]]
}

json_val() {
    python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" < "$2"
}

# ── platform ────────────────────────────────────────────────
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *)      die "Unsupported OS: $(uname -s)" ;;
esac
case "$(uname -m)" in
    x86_64)         arch="x86_64" ;;
    arm64|aarch64)  arch="aarch64" ;;
    *)              die "Unsupported architecture: $(uname -m)" ;;
esac
platform="${os}-${arch}"

# ── resolve version ─────────────────────────────────────────
if [[ -z "$version" ]]; then
    if [[ "$channel" != "stable" ]]; then
        if command -v curl &>/dev/null; then
            releases_json=$(curl -fsSL "https://api.github.com/repos/${repo}/releases")
        else
            releases_json=$(wget -qO- "https://api.github.com/repos/${repo}/releases")
        fi
        version=$(echo "$releases_json" | \
            grep -oE '"tag_name": "v[^"]+-'"${channel}"'\.[0-9]+"' | \
            sed -E 's/.*"(v[^"]+)".*/\1/' | \
            sort -t. -k1,1V -k2,2V -k3,3V -k4,4n | \
            tail -1)
        [[ -z "$version" ]] && die "No ${channel} releases found"
    else
        if command -v curl &>/dev/null; then
            version=$(curl -fsSI "https://github.com/${repo}/releases/latest" | grep -i '^location:' | sed -E 's|.*/tag/([^[:space:]]+).*|\1|')
        else
            version=$(wget --spider -S "https://github.com/${repo}/releases/latest" 2>&1 | grep -i 'location:' | tail -1 | sed -E 's|.*/tag/([^[:space:]]+).*|\1|')
        fi
        [[ -z "$version" ]] && die "Failed to fetch latest stable version"
    fi
fi

header="${bold}grove${nc} ${version} / ${dim}${platform}"
bw=10

# ── tmp ─────────────────────────────────────────────────────
tmp_dir=$(mktemp -d)
trap "rm -rf $tmp_dir" EXIT

# ── manifest ────────────────────────────────────────────────
if [[ "$channel" == "stable" ]]; then
    manifest_name="manifest.json"
else
    manifest_name="manifest-${channel}.json"
fi
download "https://github.com/${repo}/releases/download/${version}/${manifest_name}" "${tmp_dir}/manifest.json" \
    || die "Failed to download manifest"

erts_version=$(json_val "d['components']['erts']['version']" "${tmp_dir}/manifest.json")
cli_sha=$(json_val "d['components']['cli']['sha256']['${platform}']" "${tmp_dir}/manifest.json")
elixir_sha=$(json_val "d['components']['elixir']['sha256']['${platform}']" "${tmp_dir}/manifest.json")
erts_sha=$(json_val "d['components']['erts']['sha256'].get('${platform}', '')" "${tmp_dir}/manifest.json")

# ── check ERTS cache ────────────────────────────────────────
# Skip ERTS download only if the installed tree has every required OTP lib.
# Earlier releases shipped an incomplete set (missing compiler, ssl, etc.);
# detecting that lets us re-download instead of silently booting a broken daemon.
skip_erts=0
if [[ -d "${grove_home}/erts/erts-${erts_version}" ]]; then
    skip_erts=1
    required_libs=(asn1 compiler crypto erl_interface inets kernel public_key runtime_tools sasl ssl stdlib syntax_tools tools xmerl)
    for lib in "${required_libs[@]}"; do
        if ! ls -d "${grove_home}/erts/lib/${lib}-"* >/dev/null 2>&1; then
            skip_erts=0
            break
        fi
    done
fi

# ── ui: skeleton ────────────────────────────────────────────
# Reserve 8 rows of viewport before saving the cursor anchor. If we're
# near the bottom of the terminal, this forces the scroll to happen now
# (with the cursor still in-place), so the saved position won't shift
# off-screen when we start writing the box content. Critical for
# `\033[u` restores to land on the correct row.
printf '\n\n\n\n\n\n\n\n\033[8A'
echo -en "\033[s"

echo ""
echo -e "  ${dim}╭─${nc}  ${header}"
echo -e "  ${dim}│ ${nc}"
echo -e "  ${dim}│ ${nc}  ${dim}──────────${nc}  ${dim}──────────${nc}  ${dim}──────────${nc}"
echo -e "  ${dim}│ ${nc}"
echo -e "  ${dim}╰─${nc}"
echo ""

sleep $t

# ── ui: cached bar appears white ────────────────────────────
if [[ "$skip_erts" -eq 1 ]]; then
    ui_redraw "$dim" "$header" \
        "${white}━━━━━━━━━━${nc}  ${dim}──────────${nc}  ${dim}──────────${nc}" ""
    sleep $t
fi

# ── fetch (parallel) ────────────────────────────────────────
base_url="https://github.com/${repo}/releases/download/${version}"

download "${base_url}/grove-cli-${platform}.tar.gz" "${tmp_dir}/cli.tar.gz" &
pid_cli=$!
download "${base_url}/grove-elixir-${platform}.tar.gz" "${tmp_dir}/elixir.tar.gz" &
pid_elixir=$!

if [[ "$skip_erts" -eq 0 ]]; then
    download "${base_url}/grove-erts-${platform}.tar.gz" "${tmp_dir}/erts.tar.gz" &
    pid_erts=$!
fi

# Poll file sizes for progress bars
while true; do
    # Check if all downloads finished
    all_done=1
    kill -0 $pid_cli 2>/dev/null && all_done=0
    kill -0 $pid_elixir 2>/dev/null && all_done=0
    [[ "$skip_erts" -eq 0 ]] && kill -0 $pid_erts 2>/dev/null && all_done=0

    # Get file sizes (rough progress — we don't know totals, so just show activity)
    s1=$(stat -f%z "${tmp_dir}/cli.tar.gz" 2>/dev/null || echo 0)
    s2=$(stat -f%z "${tmp_dir}/elixir.tar.gz" 2>/dev/null || echo 0)

    # Estimate progress: cli is ~4MB, elixir is ~13MB
    p1=$(( s1 * 100 / 4500000 )); [[ $p1 -gt 100 ]] && p1=100
    p2=$(( s2 * 100 / 13500000 )); [[ $p2 -gt 100 ]] && p2=100

    if [[ "$skip_erts" -eq 1 ]]; then
        ui_redraw "$dim" "$header" \
            "${white}━━━━━━━━━━${nc}  $(ui_bar_w $p1 $bw)  $(ui_bar_w $p2 $bw)" ""
    else
        s3=$(stat -f%z "${tmp_dir}/erts.tar.gz" 2>/dev/null || echo 0)
        p3=$(( s3 * 100 / 50000000 )); [[ $p3 -gt 100 ]] && p3=100
        ui_redraw "$dim" "$header" \
            "$(ui_bar_w $p1 $bw)  $(ui_bar_w $p2 $bw)  $(ui_bar_w $p3 $bw)" ""
    fi

    [[ "$all_done" -eq 1 ]] && break
    sleep 0.2
done

# Wait for all to finish and check exit codes
wait $pid_cli || die "Failed to download CLI"
wait $pid_elixir || die "Failed to download Elixir release"
[[ "$skip_erts" -eq 0 ]] && { wait $pid_erts || die "Failed to download ERTS"; }

# ── ui: all white ───────────────────────────────────────────
ui_redraw "$white" "$header" \
    "${white}━━━━━━━━━━${nc}  ${white}━━━━━━━━━━${nc}  ${white}━━━━━━━━━━${nc}" ""
sleep $t

# ── verify checksums ────────────────────────────────────────
sha256_check "${tmp_dir}/cli.tar.gz" "$cli_sha" || die "Checksum failed: cli"
sha256_check "${tmp_dir}/elixir.tar.gz" "$elixir_sha" || die "Checksum failed: elixir"
if [[ "$skip_erts" -eq 0 ]] && [[ -n "$erts_sha" ]]; then
    sha256_check "${tmp_dir}/erts.tar.gz" "$erts_sha" || die "Checksum failed: erts"
fi

# ── ui: verify (bar 1 green) ───────────────────────────────
for pct in 25 50 75 100; do
    ui_redraw "$white" "$header" \
        "$(ui_bar_g $pct $bw)  ${white}━━━━━━━━━━${nc}  ${white}━━━━━━━━━━${nc}" ""
    sleep $t
done

# ── stop daemon ─────────────────────────────────────────────
# grove off now falls back to lsof + SIGTERM so a wedged beam or stale
# pidfile doesn't block upgrades. Ignore exit code regardless.
# </dev/null so the BEAM VM (inherited by `grove off`) doesn't consume
# bytes from our pipe when run as `curl … | bash`.
if [[ -x "${install_dir}/grove" ]]; then
    "${install_dir}/grove" off </dev/null &>/dev/null || true
fi

# Belt-and-suspenders: if the existing grove binary is too old to do the
# lsof fallback, kill by port directly. Matches the manual fix from
# https://github.com/grove-code/feedback-private/issues/2.
port="${GROVE_PORT:-7777}"
if command -v lsof &>/dev/null; then
    pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        echo "$pids" | xargs kill &>/dev/null || true
        sleep 1
        pids=$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null || true)
        [[ -n "$pids" ]] && echo "$pids" | xargs kill -9 &>/dev/null || true
    fi
fi
rm -f "${grove_home}/daemon.pid"

# ── extract (parallel) ──────────────────────────────────────
staging="${grove_home}/.staging"
rm -rf "$staging"
mkdir -p "${staging}/bin" "${staging}/elixir"

tar -xzf "${tmp_dir}/cli.tar.gz" -C "${staging}/bin" &
tar -xzf "${tmp_dir}/elixir.tar.gz" -C "${staging}/elixir" &
if [[ "$skip_erts" -eq 0 ]]; then
    mkdir -p "${staging}/erts"
    tar -xzf "${tmp_dir}/erts.tar.gz" -C "${staging}/erts" &
fi
wait

# ── ui: extract (bar 2 green) ──────────────────────────────
for pct in 25 50 75 100; do
    ui_redraw "$white" "$header" \
        "${green}━━━━━━━━━━${nc}  $(ui_bar_g $pct $bw)  ${white}━━━━━━━━━━${nc}" ""
    sleep $t
done

# ── atomic swap ─────────────────────────────────────────────
backup="${grove_home}/.backup"
rm -rf "$backup"

if [[ -d "${grove_home}/bin" ]] || [[ -d "${grove_home}/elixir" ]] || [[ -d "${grove_home}/erts" ]]; then
    mkdir -p "$backup"
    [[ -d "${grove_home}/bin" ]] && mv "${grove_home}/bin" "${backup}/bin" || true
    [[ -d "${grove_home}/elixir" ]] && mv "${grove_home}/elixir" "${backup}/elixir" || true
    if [[ "$skip_erts" -eq 0 ]] && [[ -d "${grove_home}/erts" ]]; then
        mv "${grove_home}/erts" "${backup}/erts" || true
    fi
fi

mkdir -p "$grove_home"
swap_failed=0
mv "${staging}/bin" "${grove_home}/bin" || swap_failed=1
mv "${staging}/elixir" "${grove_home}/elixir" || swap_failed=1
[[ "$skip_erts" -eq 0 ]] && { mv "${staging}/erts" "${grove_home}/erts" || swap_failed=1; }

if [[ "$swap_failed" -eq 1 ]]; then
    if [[ -d "$backup" ]]; then
        [[ -d "${backup}/bin" ]] && mv "${backup}/bin" "${grove_home}/bin" || true
        [[ -d "${backup}/elixir" ]] && mv "${backup}/elixir" "${grove_home}/elixir" || true
        [[ -d "${backup}/erts" ]] && mv "${backup}/erts" "${grove_home}/erts" || true
    fi
    die "Swap failed, restored from backup"
fi
rm -rf "$staging" "$backup"

# ── permissions (parallel) ──────────────────────────────────
chmod +x "${grove_home}/bin/grove" &
chmod +x "${grove_home}/bin/grove-bridge" 2>/dev/null &
chmod +x "${grove_home}/erts/erts-"*/bin/* 2>/dev/null &
chmod +x "${grove_home}/elixir/bin/"* 2>/dev/null &
wait

if [[ "$os" == "darwin" ]]; then
    xattr -dr com.apple.quarantine "${grove_home}/erts/" 2>/dev/null &
    xattr -dr com.apple.quarantine "${grove_home}/elixir/" 2>/dev/null &
    xattr -d com.apple.quarantine "${grove_home}/bin/grove" 2>/dev/null &
    xattr -d com.apple.quarantine "${grove_home}/bin/grove-bridge" 2>/dev/null &
    wait
fi

# ── manifest ────────────────────────────────────────────────
cat > "${grove_home}/manifest.json" <<MANIFEST
{
  "schema": 2,
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "version": "${version#v}",
  "channel": "${channel}",
  "components": {
    "cli": { "version": "${version#v}", "sha256": "${cli_sha}" },
    "elixir": { "version": "${version#v}", "sha256": "${elixir_sha}" },
    "erts": { "version": "${erts_version}", "sha256": "${erts_sha}" }
  }
}
MANIFEST

# ── validate ────────────────────────────────────────────────
# </dev/null on every child: when bash is fed the script via a pipe
# (curl … | bash), the BEAM VM will consume stdin and steal bytes
# the shell still needs to parse. Without this the script silently
# exits after validate, before the 'installed' banner renders.
validate_ok=1
"${grove_home}/elixir/bin/grove" eval 'IO.puts("ok")' </dev/null &>/dev/null || validate_ok=0
"${grove_home}/bin/grove" --version </dev/null &>/dev/null || validate_ok=0

# ── ui: validate (bar 3 green) ─────────────────────────────
for pct in 25 50 75 100; do
    ui_redraw "$white" "$header" \
        "${green}━━━━━━━━━━${nc}  ${green}━━━━━━━━━━${nc}  $(ui_bar_g $pct $bw)" ""
    sleep $t
done

sleep $t

# ── man page ────────────────────────────────────────────────
if [[ -f "${grove_home}/bin/grove.1" ]]; then
    man_dir="${grove_home}/share/man/man1"
    mkdir -p "$man_dir"
    mv "${grove_home}/bin/grove.1" "${man_dir}/grove.1"
fi

# ── symlink ─────────────────────────────────────────────────
if [[ -d "$HOME/.local/bin" ]]; then
    ln -sf "${grove_home}/bin/grove" "$HOME/.local/bin/grove"
fi

# ── ui: done ────────────────────────────────────────────────
if [[ "$validate_ok" -eq 1 ]]; then
    ui_redraw "$green" "$header" \
        "${green}installed${nc}" \
        "${dim}~/.grove/bin/grove${nc}"
else
    ui_redraw "$green" "$header" \
        "${green}installed${nc} ${dim}(validation warnings)${nc}" \
        "${dim}~/.grove/bin/grove${nc}"
fi

if [[ ":$PATH:" != *":${grove_home}/bin:"* ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    echo ""
    echo -e "  ${dim}add to PATH: export PATH=\"\$HOME/.grove/bin:\$PATH\"${nc}"
fi
