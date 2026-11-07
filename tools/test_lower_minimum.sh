#!/bin/bash
# Compiled LowerMinimum tests; never installs or touches game saves.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD
root=${SWZC_ROOT:-/run/media/chats/0c7bd812-03b4-405c-9602-31282b68fd64/Tools}
kit=${SWZC_KIT:-"/run/media/chats/0c7bd812-03b4-405c-9602-31282b68fd64/Projects/ZeroCompany/SDK/SWZC Merged Kit"}
mkdir -p dist/gf-logs
SQUADSIX_REPO="$repo" "$root/UnrealEngine/Engine/Binaries/Linux/UnrealEditor-Cmd" "$kit/SWZeroCompany.uproject" \
    -run=pythonscript -script="$repo/tests/unreal/test_lower_minimum.py" \
    -unattended -nop4 -nosplash -NullRHI -stdout -FullStdOutLogOutput -NoCrashDialog > dist/gf-logs/minimum-test.log 2>&1 || true
rg 'MINIMUM_(RESULT|TEST)|LogPython: Error|ZCOMAUTH.*(error|warning|FAILED)' dist/gf-logs/minimum-test.log || true
rg -q 'MINIMUM_RESULT ok' dist/gf-logs/minimum-test.log
