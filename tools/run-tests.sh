#!/bin/sh
# Run every tests/*_test.lua with LuaJIT against the runtime in src/.
# Usage: tools/run-tests.sh
cd "$(dirname "$0")/.." || exit 1
scripts="$(pwd)/src/SquadSixReforged/Scripts"
pass=0
fail=0
for t in tests/*_test.lua; do
    if out=$(luajit "$t" "$scripts" 2>&1); then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n%s\n\n' "$t" "$out" | head -40
    fi
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
