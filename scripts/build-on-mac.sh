#!/bin/bash
# Build the nabu xnu-8796 kernel on a rented Mac (no GitHub Actions needed).
#
# Everything the CI does, in one script:
#   * fetch blacktop/darwin-xnu-build at the pinned SHA
#   * drop in our patch set (with CRLF stripped and the arm64 arch fix)
#   * pick Xcode 15 if installed (Xcode 16 breaks xnu-8796, see the workflow)
#   * build and leave the kernel in ./out/
#
# Usage:  bash build-on-mac.sh [/path/to/unixnu-nabu-build]
#   With no argument it clones the public repo into ./unixnu-nabu-build.

set -uo pipefail

REPO_URL="${REPO_URL:-https://github.com/3214791900-del/unixnu-nabu-build}"
REPO_REF="${REPO_REF:-nabu-gpu-port}"
DXB_REPO="https://github.com/blacktop/darwin-xnu-build"
DXB_SHA="663906528d1cd5ea8fde7de6f16de73db9511549"
KERNEL_CONFIG="${KERNEL_CONFIG:-DEVELOPMENT}"
MACHINE_CONFIG="${MACHINE_CONFIG:-NABU}"
WORK="${WORK:-$PWD/work}"

log() { printf '\n=== %s ===\n' "$*"; }

log "host"
sw_vers || true
uname -m
df -h / | tail -1

log "fetch our patch set"
SRC="${1:-}"
if [ -z "$SRC" ]; then
	if [ ! -d unixnu-nabu-build/.git ]; then
		git clone --depth 1 -b "$REPO_REF" "$REPO_URL" unixnu-nabu-build || exit 1
	fi
	SRC="$PWD/unixnu-nabu-build"
fi
ls "$SRC/xnu-8796/patches" | wc -l

log "fetch darwin-xnu-build @ $DXB_SHA"
mkdir -p "$WORK" && cd "$WORK" || exit 1
if [ ! -d dxb/.git ]; then
	git init -q dxb
	git -C dxb fetch -q --depth 1 "$DXB_REPO" "$DXB_SHA" || exit 1
	git -C dxb checkout -q FETCH_HEAD || exit 1
fi
cd dxb || exit 1

log "stage patches"
mkdir -p patches
cp "$SRC"/xnu-8796/patches/*.patch patches/ 2>/dev/null
cp "$SRC"/xnu-8796/patches/*.sh patches/ 2>/dev/null
for f in patches/*.patch patches/*.sh; do
	[ -e "$f" ] || continue
	perl -pi -e 's/\r$//' "$f"
done
ls patches | wc -l

log "build.sh: allow plain arm64"
if grep -q 'ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"' build.sh; then
	sed -i '' 's/ARCHS="x86_64 arm64e" VALID_ARCHS="x86_64 arm64e"/ARCHS="x86_64 arm64e arm64" VALID_ARCHS="x86_64 arm64e arm64"/' build.sh
fi
grep -c 'VALID_ARCHS="x86_64 arm64e arm64"' build.sh || true

log "tooling"
# build.sh refuses to run unless jq, gum, xcodes, cmake and ninja are all on
# PATH, and its fallback is `brew install`, which stalls for tens of minutes on
# AppVeyor's cold cache. It then REPLACES PATH with the Xcode toolchain plus
# /usr/local/bin, so everything has to live there or it vanishes mid-build:
#   * jq and ninja are single-binary releases, gum a tarball, all from GitHub
#   * xcodes only installs Xcode, and 15.2 is already on the image, so it gets
#     a no-op stub exactly like the GitHub workflow does
TOOLBIN=/usr/local/bin
if [ ! -w "$TOOLBIN" ]; then
	SUDO=sudo
else
	SUDO=
fi
install_tool() {
	$SUDO install -m 0755 "$1" "$TOOLBIN/$2" && echo "installed $2 -> $TOOLBIN"
}

printf '#!/bin/sh\nexit 0\n' > /tmp/xcodes-stub
chmod +x /tmp/xcodes-stub
install_tool /tmp/xcodes-stub xcodes

fetch_bin() {
	# fetch_bin <url> <name>
	if curl -fsSL --retry 3 --max-time 180 -o "/tmp/$2.dl" "$1"; then
		chmod +x "/tmp/$2.dl"
		install_tool "/tmp/$2.dl" "$2"
	else
		echo "WARNING: could not fetch $2 from $1"
	fi
}

command -v jq >/dev/null || fetch_bin \
	"https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-amd64" jq

if ! command -v ninja >/dev/null; then
	if curl -fsSL --retry 3 --max-time 180 -o /tmp/ninja.zip \
		"https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-mac.zip"; then
		unzip -oq /tmp/ninja.zip -d /tmp/ninja-dir && install_tool /tmp/ninja-dir/ninja ninja
	fi
fi

if ! command -v gum >/dev/null; then
	if curl -fsSL --retry 3 --max-time 180 -o /tmp/gum.tgz \
		"https://github.com/charmbracelet/gum/releases/download/v0.14.5/gum_0.14.5_Darwin_x86_64.tar.gz"; then
		mkdir -p /tmp/gum-dir && tar -xzf /tmp/gum.tgz -C /tmp/gum-dir \
			&& install_tool /tmp/gum-dir/gum gum
	fi
fi
command -v gum >/dev/null || { echo "gum unavailable, stubbing"; install_tool /tmp/xcodes-stub gum; }

export PATH="$TOOLBIN:$PATH"
echo "tooling step done at $(date +%H:%M:%S); have:" \
	"jq=$(command -v jq || echo no)" "gum=$(command -v gum || echo no)" \
	"xcodes=$(command -v xcodes || echo no)" "cmake=$(command -v cmake || echo no)" \
	"ninja=$(command -v ninja || echo no)"

log "pick Xcode"
XC=""
for cand in /Applications/Xcode_15*.app /Applications/Xcode-15*.app; do
	[ -d "$cand" ] && XC="$cand" && break
done
if [ -z "$XC" ]; then
	XC=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | head -1)
fi
if [ -z "$XC" ]; then
	echo "NO XCODE FOUND: install Xcode 15 from the App Store or developer.apple.com"
	exit 1
fi
echo "picked: $XC"
export DEVELOPER_DIR="$XC/Contents/Developer"
sudo xcode-select -s "$XC" 2>/dev/null || true
xcodebuild -version || true
xcrun --find iig || true

log "build (this takes 5-15 min)"
set -o pipefail
MAKEFLAGS=-k bash build.sh 2>&1 | tee build.log
rc=$?
echo "=== build.sh exit: $rc ==="
if [ "$rc" -ne 0 ]; then
	echo "--- first errors ---"
	grep -E 'error:|Error [0-9]|Undefined symbol' build.log | head -30
fi

log "collect"
mkdir -p ../out
cp -R fakeroot/System/Library/Kernels/. ../out/ 2>/dev/null || true
ls -la ../out 2>/dev/null || true
(cd ../out && shasum -a 256 kernel.* 2>/dev/null) || true

if [ -f ../out/kernel.development.nabu ]; then
	log "SUCCESS"
	echo "kernel: $WORK/out/kernel.development.nabu"
else
	log "no kernel produced"
	exit 1
fi
