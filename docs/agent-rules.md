# Rules for every mod repo

<!-- SHARED FILE: owned by ModTemplate and copied in by `make sync`; never edit it in a mod repo.
     Each repo's CLAUDE.md imports this, then adds its own rules. -->

## Working in the repo

- Use the `make` targets (`make help`), not the scripts behind them: `make test`, `make package`,
  `make install`, `make bump V=…`, `make release`, `make check`.
- The layout and every shared file are defined in `../ModTemplate` (STANDARD.md, GLOSSARY.md).
  A file marked SHARED FILE is edited only in ModTemplate, then copied in with `make sync`.
- The version lives in `release.json`; `make bump` writes every other copy. Never hand-edit a
  version in `modinfo.json`, `zcom-mod.json` or `main.lua`.
- Write release notes under `## [Unreleased]` in CHANGELOG.md as you go; `make bump` dates them.
- Shipped folder names under `src/` never change, even when they contain spaces: players already
  have them installed (ModTemplate ADR 0001).
- `make release` pushes a tag that publishes to GitHub and Nexus. Run it only when the user asks.

## The game

- The main install is linked to these repos. Never disable a mod by renaming `enabled.txt` (or
  anything else) inside `src/`: that disables it everywhere. Use `make uninstall` or `mods.txt`.
- Restarting the game during a test loop is fine without asking. UE4SS mods don't hot-reload.
- Never use one of the user's real campaigns as a disposable test save; ask which save to use.
- UE4SS 3.0.1 in this game crashes on `obj.Prop = FText(...)`; use `SetTextPropertyByName`.
- A third `GE_Injured` stack kills an operator; cap test injuries at two.
