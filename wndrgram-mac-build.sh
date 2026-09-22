#!/bin/bash
#
# WndrGram for iOS — one-shot setup + build on macOS.
#
# This folder came from a GitHub zip, which does not include git submodules
# (webrtc, td, rules_apple, …). The script clones upstream Telegram-iOS at the
# exact commit the zip was made from, pulls every submodule, copies the
# WndrGram sources from this folder on top, and builds for the simulator.
#
# Usage (from this folder):
#   ./wndrgram-mac-build.sh            # set up (first run) + simulator build
#   ./wndrgram-mac-build.sh --device   # build for a real iPhone (see guide)
#
set -euo pipefail

UPSTREAM_URL="https://github.com/TelegramMessenger/Telegram-iOS.git"
UPSTREAM_COMMIT="6ad963e5b62d354da79040f388ae2b9132fb17b8"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="${WNDRGRAM_WORK_DIR:-$HOME/WndrGram-iOS}"
CACHE_DIR="$HOME/telegram-bazel-cache"
MODE="sim"
if [ "${1:-}" = "--device" ]; then
    MODE="device"
fi

echo "==> Checking tools"
command -v git >/dev/null || { echo "git not found: install Xcode Command Line Tools (xcode-select --install)"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode not found: install Xcode from the App Store"; exit 1; }
xcodebuild -version | sed -n 1p

if [ ! -d "$WORK_DIR/.git" ]; then
    echo "==> Cloning upstream Telegram-iOS into $WORK_DIR (large, takes a while)"
    git clone "$UPSTREAM_URL" "$WORK_DIR"
    git -C "$WORK_DIR" checkout "$UPSTREAM_COMMIT"
fi

echo "==> Fetching submodules"
git -C "$WORK_DIR" submodule update --init --recursive --jobs 8

echo "==> Copying WndrGram sources on top"
# Submodule folders are empty in the zip, so they are excluded to keep the
# freshly cloned ones intact.
rsync -a \
    --exclude '.git' \
    --exclude 'submodules/rlottie/rlottie' \
    --exclude 'build-system/bazel-rules/rules_apple' \
    --exclude 'build-system/bazel-rules/rules_swift' \
    --exclude 'build-system/bazel-rules/apple_support' \
    --exclude 'build-system/bazel-rules/rules_xcodeproj' \
    --exclude 'build-system/bazel-rules/sourcekit-bazel-bsp' \
    --exclude 'submodules/TgVoipWebrtc/tgcalls' \
    --exclude 'submodules/LottieCpp/lottiecpp' \
    --exclude 'third-party/libvpx/libvpx' \
    --exclude 'third-party/webrtc/webrtc' \
    --exclude 'third-party/dav1d/dav1d' \
    --exclude 'third-party/td/td' \
    --exclude 'third-party/XcodeGen' \
    --exclude 'bazel-*' \
    "$SRC_DIR/" "$WORK_DIR/"

cd "$WORK_DIR"

echo "==> Restoring executable bits"
# This tree came from a zip made on Windows, so the copy above strips the
# executable bit from every build script; take the modes from upstream git.
git ls-files -s | awk '$1 == "100755" { print $4 }' | while IFS= read -r f; do
    [ -f "$f" ] && chmod +x "$f"
done

echo "==> Importing Telegram's test signing certificates into the keychain"
python3 build-system/Make/ImportCertificates.py --path build-system/fake-codesigning/certs

if [ "$MODE" = "sim" ]; then
    CONFIGURATION="debug_sim_arm64"
    echo "==> Building for the iOS Simulator (first build: 30-90 minutes)"
else
    CONFIGURATION="release_arm64"
    echo "==> Building an IPA for a real iPhone (first build: 30-90 minutes)"
fi

python3 -u build-system/Make/Make.py --overrideXcodeVersion     --cacheDir "$CACHE_DIR"     build     --continueOnError     --configurationPath build-system/appstore-configuration.json     --codesigningInformationPath build-system/fake-codesigning     --buildNumber=1     --configuration="$CONFIGURATION"

IPA="$(find -L bazel-out -path '*/bin/Telegram/Telegram.ipa' -newer "$SRC_DIR/wndrgram-mac-build.sh" 2>/dev/null | sed -n 1p || true)"
if [ -z "$IPA" ]; then
    IPA="$(find -L bazel-out -path "*/bin/Telegram/Telegram.ipa" 2>/dev/null | sed -n 1p || true)"
fi
if [ -z "$IPA" ]; then
    echo "Build finished but no Telegram.ipa was found under bazel-out"
    exit 1
fi
mkdir -p "$WORK_DIR/out"
cp "$IPA" "$WORK_DIR/out/WndrGram-$MODE.ipa"
echo
echo "==> Done: $WORK_DIR/out/WndrGram-$MODE.ipa"
if [ "$MODE" = "sim" ]; then
    echo "    Install into the booted simulator:"
    echo "      cd /tmp && rm -rf Payload && unzip -o \"$WORK_DIR/out/WndrGram-sim.ipa\" >/dev/null && xcrun simctl install booted /tmp/Payload/Telegram.app"
else
    echo "    Sign and install it on the iPhone with Sideloadly or AltStore (see the guide)."
fi
