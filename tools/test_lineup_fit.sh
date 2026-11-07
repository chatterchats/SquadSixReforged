#!/bin/bash
# Compiled squad-screen lineup fit tests; never installs or touches game saves.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
root=${SWZC_ROOT:-/run/media/chats/0c7bd812-03b4-405c-9602-31282b68fd64}
kit=${SWZC_KIT:-"$root/SWZC Merged Kit"}
mkdir -p dist/gf-logs
SQUADSIX_REPO="$repo" "$root/UnrealEngine/Engine/Binaries/Linux/UnrealEditor-Cmd" "$kit/SWZeroCompany.uproject" \
    -run=pythonscript -script="$repo/tests/unreal/test_lineup_fit.py" \
    -unattended -nop4 -nosplash -NullRHI -stdout -FullStdOutLogOutput -NoCrashDialog > dist/gf-logs/lineup-test.log 2>&1 || true
rg 'LINEUP_(RESULT|TEST)|LogPython: Error|ZCOMAUTH.*(error|warning|FAILED)' dist/gf-logs/lineup-test.log || true
rg -q 'LINEUP_RESULT ok' dist/gf-logs/lineup-test.log
