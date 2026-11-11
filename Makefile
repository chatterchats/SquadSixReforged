include tools/mod.mk

# Squad Six ships a cooked Game Feature. The paks are committed (cooking needs the Linux Unreal
# kit, which CI lacks), and unreal/build.json records what they were cooked from.

build-gf: ## Cook the Game Feature (Linux kit) and copy its paks into src/
	tools/build_gf.sh
	python3 tools/gf_build.py record

package-extra:: ## (refuses paks that are stale against unreal/build.json)
	@python3 tools/gf_build.py check

# The Lua tests cover the retired v1 runtime in dev/v1. A second pass takes away what LuaJIT has
# and UE4SS's Lua 5.4 lacks (tests/lua54.lua).
test-extra::
	@if [ "$$SKIP_LUA_TESTS" = 1 ]; then exit 0; fi; \
	fail=0; for t in tests/*_test.lua; do \
	    luajit -e "dofile('tests/lua54.lua')" "$$t" >/dev/null 2>&1 || { echo "FAIL  $$t (Lua 5.4 pass)"; fail=1; }; \
	done; [ $$fail -eq 0 ] && echo "Lua 5.4 pass: all ok"
