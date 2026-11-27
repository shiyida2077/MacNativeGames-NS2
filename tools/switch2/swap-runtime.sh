#!/bin/sh
# Replace the game binary inside an existing .app without re-packaging its assets.
#
#   swap-runtime.sh <MyGame.app> <path/to/new-binary>
#
# The runtime is statically linked into the game's Mach-O, so "updating the
# runtime" means recompiling that binary (make build/totk-native-<target>) and
# swapping it in. This script also makes sure the Bluetooth usage description
# exists and re-signs ad-hoc. Game data, saves and resources are untouched.
set -eu

app=${1:?usage: swap-runtime.sh <MyGame.app> <new-binary>}
bin=${2:?usage: swap-runtime.sh <MyGame.app> <new-binary>}
plist="$app/Contents/Info.plist"
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")

[ -x "$bin" ] || { echo "not an executable: $bin" >&2; exit 1; }

echo "app:  $app"
echo "exe:  $exe"
cp "$bin" "$app/Contents/MacOS/$exe"

if /usr/libexec/PlistBuddy -c 'Print :NSBluetoothAlwaysUsageDescription' "$plist" >/dev/null 2>&1; then
  echo "bluetooth usage description: already present"
else
  /usr/libexec/PlistBuddy -c \
    'Add :NSBluetoothAlwaysUsageDescription string "Switch 2 controllers connect to the game over Bluetooth."' \
    "$plist"
  echo "bluetooth usage description: added"
fi

echo "signing (ad-hoc, may take a few minutes on a 20 GB bundle)..."
codesign --force --deep -s - "$app"
codesign --verify --deep --strict "$app"
echo "done: $app"
