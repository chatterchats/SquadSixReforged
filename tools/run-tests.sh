#!/bin/sh
# Run every tests/*_test.lua with LuaJIT against the runtime in src/, then again with what Lua 5.4
# (the Lua inside UE4SS) lacks taken away (tests/lua54.lua).
# Usage: tools/run-tests.sh
cd "$(dirname "$0")/.." || exit 1
scripts="$(pwd)/src/SquadSixReforged/Scripts"
pass=0
fail=0
for mode in luajit lua54; do
    for t in tests/*_test.lua; do
        if [ "$mode" = lua54 ]; then
            out=$(luajit -e "dofile('tests/lua54.lua')" "$t" "$scripts" 2>&1)
        else
            out=$(luajit "$t" "$scripts" 2>&1)
        fi
        if [ $? -eq 0 ]; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
            printf 'FAIL %s (%s)\n%s\n\n' "$t" "$mode" "$out" | head -40
        fi
    done
done
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
