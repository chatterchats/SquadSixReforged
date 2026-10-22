#!/bin/bash
# Compiled deterministic rescue tests; never installs or touches game saves.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
root=${SWZC_ROOT:-/run/media/chats/0c7bd812-03b4-405c-9602-31282b68fd64}
kit=${SWZC_KIT:-"$root/SWZC Merged Kit"}
mkdir -p dist/gf-logs
SQUADSIX_REPO="$repo" "$root/UnrealEngine/Engine/Binaries/Linux/UnrealEditor-Cmd" "$kit/SWZeroCompany.uproject" \
    -run=pythonscript -script="$repo/tests/unreal/test_spawn_rescue.py" \
    -unattended -nop4 -nosplash -NullRHI -stdout -FullStdOutLogOutput -NoCrashDialog > dist/gf-logs/spawn-test.log 2>&1 || true
rg 'SPAWN_(RESULT|TEST)|LogPython: Error|ZCOMAUTH.*(error|warning|FAILED)' dist/gf-logs/spawn-test.log || true
rg -q 'SPAWN_RESULT ok' dist/gf-logs/spawn-test.log
