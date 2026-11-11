# The standard targets every mod repo has.
# SHARED FILE: owned by ModTemplate and copied in by `make sync`; never edit it in a mod repo.
#
# A repo's Makefile includes this, then may add:
#   - hook recipes, which run as part of the standard targets:
#       test-extra::      after the standard tests
#       package-extra::   before the zip is built (e.g. check committed paks)
#       install-extra::   after the shipped folders are installed
#       uninstall-extra:: after they are removed
#   - its own targets, documented with "## text" so `make help` lists them.

MODTOOL := python3 tools/modtool.py
.DEFAULT_GOAL := help
.PHONY: help test package install uninstall bump release check sync \
        test-extra package-extra install-extra uninstall-extra

help: ## List the targets
	@$(MODTOOL) help $(MAKEFILE_LIST)

test: ## Run every test (Lua and Python); no game needed
	@$(MODTOOL) test $(T)
	@$(MAKE) --no-print-directory test-extra

package: ## Build dist/<Repo>-X.Y.Z.zip and its .sha256
	@$(MAKE) --no-print-directory package-extra
	@$(MODTOOL) package $(if $(FORCE),--force)

install: ## Link the shipped folders into the main install
	@$(MODTOOL) install
	@$(MAKE) --no-print-directory install-extra

uninstall: ## Remove what install placed (never touches enabled.txt)
	@$(MODTOOL) uninstall
	@$(MAKE) --no-print-directory uninstall-extra

bump: ## Set the version everywhere and date the changelog: make bump V=1.2.3 (or V=patch)
	@test -n "$(V)" || { echo "usage: make bump V=X.Y.Z|major|minor|patch"; exit 2; }
	@$(MODTOOL) bump $(V)

release: ## Check, test, package, tag vX.Y.Z and push (CI publishes)
	@$(MAKE) --no-print-directory package-extra
	@$(MODTOOL) release $(if $(NO_PUSH),--no-push)

check: ## Report drift from the ModTemplate standard
	@$(MODTOOL) check

sync: ## Copy the latest shared files from ModTemplate
	@$(MODTOOL) sync

test-extra:: ; @:
package-extra:: ; @:
install-extra:: ; @:
uninstall-extra:: ; @:
