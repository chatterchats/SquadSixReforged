#!/usr/bin/env python3
"""Check Squad Six in the running game through ZC Sandbox (development only).

Drives "ZC Unlocked - Sandbox Mode" (ue4ss/Mods/ZCSandbox) through its command file, on a game copy
("<games>/Instance N", as Off Duty's simtest uses): launch a mission with a six-operator squad,
let the dev probe (dev/SquadSixReforgedProbe) watch the staging, the relocation and the placement
spots, optionally end encounters with the game's own fatal damage (`kill foes`) to reach the
next deployment, then return to the Den. Squad Six's and the probe's log lines for each mission
go into one report under dist/sandbox/.

    tools/sandbox_check.py install   [--instance 2]     copy this repo's build into a game copy
    tools/sandbox_check.py uninstall [--instance 2]     take it out again (probe output is kept)
    tools/sandbox_check.py status    [--instance 2]     what's installed, is the game up
    tools/sandbox_check.py info      [--instance 2] [filter]   roster and mission names
    tools/sandbox_check.py send      [--instance 2] "<sandbox command>"   one raw command
    tools/sandbox_check.py check     [--instance 2] --squad "A,B,C,D,E,F" \\
        --missions SK_Lothal_035_Crisis,MM_01_010_SerolonisJob,MM_04_030_RetakeLuunata:advance=2

Rules (from Off Duty's simtest handoff):
- A human starts the game copy and leaves it at the main menu or in the sandbox Den. This tool
  never launches or kills the game.
- Never install or uninstall while that copy is running; `install` refuses to.
- Only one harness at a time: they share one cmd.txt/reply.txt pair.
- Use a copy, not the main install (instance 1): installing Squad Six there changes the squad size
  of your real campaigns. `--allow-main` overrides.
- Don't run alongside Squad Expansion: both change the squad size, and its DLL refuses to run
  next to Squad Six.
On a crash the check stops; the dump is under the copy's prefix (see the report). Ask the human
to restart the game, then run the remaining missions.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAMES = Path(os.environ.get("SWZC_GAMES", "/run/media/chats/e0057d4a-fe46-43eb-a837-db51979c500f/Games/"
                            "STAR WARS Zero Company (2026)"))
GAME_DIR = Path("Star Wars Zero Company")
WIN64 = GAME_DIR / "SWZeroCompany" / "Binaries" / "Win64"
PAKS = GAME_DIR / "SWZeroCompany" / "Content" / "Paks" / "~mods"
CRASHES = Path("prefix/drive_c/users/steamuser/AppData/Local/SWZeroCompany/Saved/Crashes")

RUNTIME_SOURCE = ROOT / "src" / "SquadSixReforged"
CORE_SOURCE = ROOT / "src" / "SquadSixReforged_Core"
CORE_FOLDER = "SquadSixReforged_Core"  # under ~mods, as the release ZIP installs it
PROBE_SOURCE = ROOT / "dev" / "SquadSixReforgedProbe"
# Development-only settings page entries (the debug markers), added to the installed page.
DEV_SETTINGS = ROOT / "dev" / "mxm" / "debug_settings.lua"
RUNTIME_MOD, PROBE_MOD = "SquadSixReforged", "SquadSixReforgedProbe"
PAK_FILES = ["pakchunk99-SquadSixReforged_P." + extension for extension in ("pak", "ucas", "utoc")]
PROBE_OUTPUT = ["squadsix_probe.log", "squadsix_probe.jsonl"]
# Other squad-size mods: a Mods folder name, or a pak file name prefix.
CONFLICTS = ["SquadExpansion", "pakchunk99-SquadExpansion_P"]
TAGS = ("[SQUAD_SIX_REFORGED]", "[SQUADSIX_PROBE]", "[ZCOM_SQUAD_SIX]")  # the last: logs from before the rename
# Earlier dev installs under arctco's Squad Six names (up to 1.2.0's rename to Squad Six Reforged).
# On a game copy they're ours, so install and uninstall remove them; both would load otherwise.
LEGACY_MODS = ["ZCOMSquadSix", "ZCOMSquadSixProbe"]
LEGACY_CORE_FOLDER = "ZCOMSquadSix_Core"
LEGACY_PAK_FILES = ["pakchunk99-ZCOMSquadSix_P." + extension for extension in ("pak", "ucas", "utoc")]


class Instance:
    """A game install: 1 is the main one, n >= 2 is GAMES/"Instance n"."""

    def __init__(self, number):
        self.number = number
        self.base = GAMES if number == 1 else GAMES / ("Instance %d" % number)
        self.win64 = self.base / WIN64
        self.mods = self.win64 / "ue4ss" / "Mods"
        self.paks = self.base / PAKS
        self.sandbox = self.mods / "ZCSandbox"
        self.ue4ss_log = self.win64 / "ue4ss" / "UE4SS.log"
        self.crashes = self.base / CRASHES
        self.probe = self.mods / PROBE_MOD

    def running(self):
        """Is this copy's game up? A game process whose command line names "Instance N" is that copy;
        any other game process is the main install."""
        try:
            listing = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
        except OSError:
            return False
        for line in listing.splitlines():
            if not re.search(r"SWZeroCompany(-Win64-Shipping)?\.exe", line, re.I):
                continue
            copy = re.search(r"Instance (\d+)", line)
            if (int(copy.group(1)) if copy else 1) == self.number:
                return True
        return False

    def crash_dumps(self):
        return set(p.name for p in self.crashes.glob("UECC-*")) if self.crashes.is_dir() else set()


class SandboxError(RuntimeError):
    pass


class Sandbox:
    """cmd.txt / reply.txt client, as in ZComOffDuty/tools/simtest.py. Ids are unique per process."""

    def __init__(self, folder, transcript=None):
        self.cmd = Path(folder) / "cmd.txt"
        self.reply = Path(folder) / "reply.txt"
        self.prefix = "sx%d" % (os.getpid() % 100000)
        self.counter = 0
        self.transcript = transcript

    def hello(self):
        try:
            first = self.reply.read_text(errors="replace").splitlines()[0]
        except (OSError, IndexError):
            return None
        return first if first.startswith("hello ok session") else None

    def log(self, text):
        if self.transcript:
            self.transcript.write(text + "\n")
            self.transcript.flush()

    def send(self, line, timeout=None):
        """Send one command; return (status, text). Waits for the reply carrying our id."""
        self.counter += 1
        rid = "%sn%d" % (self.prefix, self.counter)
        if timeout is None:
            match = re.search(r"\btimeout=(\d+)", line)
            timeout = (int(match.group(1)) / 1000 if match else 30) + 10
        # A one-line file each time: under Proton the sandbox sees every write from Linux as the
        # file being replaced and re-reads it from the top, so appending replayed the history.
        with open(self.cmd, "w", newline="\r\n") as handle:
            handle.write("#%s %s\n" % (rid, line))
        self.log("> " + line)
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                for raw in self.reply.read_text(errors="replace").splitlines():
                    if raw.startswith(rid + " "):
                        rest = raw[len(rid) + 1:]
                        status = rest.split(" ", 1)[0]
                        text = rest.split("|", 1)[1].strip() if "|" in rest else rest
                        self.log("< %s %s" % (status, text))
                        return status, text
            except OSError:
                pass
            time.sleep(0.25)
        self.log("< timeout")
        raise SandboxError("no reply to %r within %ds" % (line, timeout))


def session(instance, transcript=None):
    sandbox = Sandbox(instance.sandbox, transcript)
    # reply.txt keeps the last session's hello after the game closes, so check the process too.
    if not instance.running() or not sandbox.hello():
        sys.exit("No sandbox session on instance %d: start that game copy (it should reach the main menu or "
                 "the sandbox Den) and try again. Looked for a hello line in %s" % (instance.number, sandbox.reply))
    return sandbox


# ---- install --------------------------------------------------------------------------------------------

def git_identity():
    def git(*args):
        return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True).stdout.strip()
    commit = git("rev-parse", "--short", "HEAD") or "unknown"
    dirty = bool(git("status", "--porcelain", "--", "src", "dev"))
    return commit + ("+uncommitted" if dirty else "")


def refuse_unsafe(instance, allow_main):
    if instance.number == 1 and not allow_main:
        sys.exit("Instance 1 is the main install: Squad Six there changes your real campaigns' squad size. "
                 "Use a copy (--instance 2) or pass --allow-main.")
    if not instance.mods.is_dir():
        sys.exit("No game at %s" % instance.base)
    if instance.running():
        sys.exit("Instance %d's game is running: close it before installing or uninstalling." % instance.number)


def remove_legacy(instance, kept):
    """Remove dev installs under the old names; the old probe's output goes to kept."""
    removed = []
    old_probe = instance.mods / "ZCOMSquadSixProbe"
    for name in PROBE_OUTPUT:
        if (old_probe / name).exists():
            kept.mkdir(parents=True, exist_ok=True)
            shutil.move(str(old_probe / name), str(kept / ("legacy-" + name)))
    for name in LEGACY_MODS:
        if (instance.mods / name).exists():
            shutil.rmtree(instance.mods / name)
            removed.append("Mods/" + name)
    if (instance.paks / LEGACY_CORE_FOLDER).exists():
        shutil.rmtree(instance.paks / LEGACY_CORE_FOLDER)
        removed.append("~mods/" + LEGACY_CORE_FOLDER)
    for name in LEGACY_PAK_FILES:
        if (instance.paks / name).exists():
            (instance.paks / name).unlink()
            removed.append("~mods/" + name)
    if removed:
        print("Removed the old-name install from instance %d: %s" % (instance.number, ", ".join(removed)))


def probe_output_dir(instance):
    return ROOT / "dist" / "sandbox" / ("instance%d-probe-output" % instance.number)


def add_dev_settings(page):
    """Insert dev/mxm/debug_settings.lua's entries at the end of the installed page's settings
    list (the release page leaves them out)."""
    entries = "".join(line + "\n" for line in DEV_SETTINGS.read_text().splitlines()
                      if not line.startswith("--"))
    text = page.read_text()
    end = "    },\n}\n"
    assert text.endswith(end), f"{page}: settings list doesn't end as expected"
    page.write_text(text[:-len(end)] + entries + end)


def cmd_install(args):
    instance = Instance(args.instance)
    refuse_unsafe(instance, args.allow_main)
    present = [name for name in CONFLICTS if (instance.mods / name).exists()
               or any(p.name.startswith(name) for p in instance.paks.glob("*"))]
    if present:
        sys.exit("Another squad-size mod is installed on instance %d (%s); remove it first." % (
            instance.number, ", ".join(present)))
    remove_legacy(instance, probe_output_dir(instance))
    runtime = instance.mods / RUNTIME_MOD
    # The player's settings page choices (Mixamoo Mod Config Manager) survive a reinstall.
    values = runtime / "MXM" / "values.lua"
    kept_values = values.read_bytes() if values.is_file() else None
    if runtime.exists():
        shutil.rmtree(runtime)
    shutil.copytree(RUNTIME_SOURCE, runtime)
    if kept_values is not None:
        values.write_bytes(kept_values)
    add_dev_settings(runtime / "MXM" / "settings.lua")
    (runtime / "enabled.txt").write_text("")
    # The release keeps the paks in ~mods/SquadSixReforged_Core; never leave a loose copy beside it.
    for name in PAK_FILES:
        (instance.paks / name).unlink(missing_ok=True)
    core = instance.paks / CORE_FOLDER
    if core.exists():
        shutil.rmtree(core)
    shutil.copytree(CORE_SOURCE, core)
    # The probe: replace its scripts, keep its output files.
    probe_scripts = instance.probe / "Scripts"
    if probe_scripts.exists():
        shutil.rmtree(probe_scripts)
    shutil.copytree(PROBE_SOURCE / "Scripts", probe_scripts)
    for name in ("enabled.txt", "README.md"):
        shutil.copyfile(PROBE_SOURCE / name, instance.probe / name)
    stamp = "%s installed %s\n" % (git_identity(), datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    (runtime / "installed_from.txt").write_text(stamp)
    print("Installed Squad Six Reforged %s and the probe on instance %d." % (stamp.split()[0], instance.number))


def cmd_uninstall(args):
    instance = Instance(args.instance)
    refuse_unsafe(instance, args.allow_main)
    kept = probe_output_dir(instance)
    remove_legacy(instance, kept)
    for name in PROBE_OUTPUT:
        if (instance.probe / name).exists():
            kept.mkdir(parents=True, exist_ok=True)
            shutil.move(str(instance.probe / name), str(kept / name))
    for folder in (instance.mods / RUNTIME_MOD, instance.probe):
        if folder.exists():
            shutil.rmtree(folder)
    for name in PAK_FILES:
        (instance.paks / name).unlink(missing_ok=True)
    if (instance.paks / CORE_FOLDER).exists():
        shutil.rmtree(instance.paks / CORE_FOLDER)
    print("Removed Squad Six Reforged and the probe from instance %d.%s" % (
        instance.number, " Probe output moved to %s" % kept if kept.exists() else ""))


def cmd_status(args):
    instance = Instance(args.instance)
    marker = instance.mods / RUNTIME_MOD / "installed_from.txt"
    print("instance %d: %s" % (instance.number, instance.base))
    print("  installed: %s" % (marker.read_text().strip() if marker.exists() else "no"))
    core = instance.paks / CORE_FOLDER
    loose = [n for n in PAK_FILES if (instance.paks / n).exists()]
    print("  pak: %s%s" % ("yes" if all((core / n).exists() for n in PAK_FILES) else "no",
                           " (and a loose copy in ~mods: reinstall)" if loose else ""))
    legacy = [n for n in LEGACY_MODS if (instance.mods / n).exists()] + (
        [LEGACY_CORE_FOLDER] if (instance.paks / LEGACY_CORE_FOLDER).exists() else []) + [
        n for n in LEGACY_PAK_FILES if (instance.paks / n).exists()]
    if legacy:
        print("  old-name install still present (install removes it): %s" % ", ".join(legacy))
    print("  probe: %s" % ("yes" if (instance.probe / "Scripts" / "main.lua").exists() else "no"))
    print("  game running: %s" % instance.running())
    hello = Sandbox(instance.sandbox).hello()
    if hello and not instance.running():
        hello = "none (reply.txt still has the last session's hello)"
    print("  sandbox session: %s" % (hello or "none"))


def cmd_info(args):
    instance = Instance(args.instance)
    sandbox = session(instance)
    for line in ("status", "campaign status", "roster", "missions " + (args.filter or "")):
        status, text = sandbox.send(line)
        print("%s -> %s | %s" % (line, status, text))


# ---- check ----------------------------------------------------------------------------------------------

def read_from(path, offset):
    """Text appended to a file since `offset` (from the start if it was rotated)."""
    try:
        size = path.stat().st_size
    except OSError:
        return "", 0
    if size < offset:
        offset = 0
    with open(path, "rb") as handle:
        handle.seek(offset)
        data = handle.read()
    return data.decode("utf-8", errors="replace"), size


def size_of(path):
    try:
        return path.stat().st_size
    except OSError:
        return 0


def parse_spec(spec):
    name, _, options = spec.partition(":")
    advance = 0
    for option in filter(None, options.split(";")):
        key, _, value = option.partition("=")
        if key == "advance":
            advance = int(value or 1)
        else:
            raise SystemExit("unknown mission option %r in %r" % (key, spec))
    return name, advance


def log_entries(text):
    """UE4SS.log entries. This game's log doesn't always end an entry with a newline, so entries
    are split at their "[YYYY-MM-DD hh:mm:ss.fff]" stamps rather than at line ends."""
    return [entry.strip() for entry in re.split(r"(?=\[20\d\d-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\])", text)
            if entry.strip()]


def probe_summary(records):
    """Problems among the probe's area checks (the latest check of each area), and the squad
    sizes it saw."""
    lines, squads, latest = [], set(), {}
    for record in records:
        if record.get("type") == "area":
            latest[record.get("key")] = record
    records = [r for r in records if r.get("type") != "area"] + list(latest.values())
    for record in records:
        if record.get("type") == "squad":
            squads.add(len(record.get("members", [])))
            continue
        if record.get("type") != "area":
            continue
        counts = []
        for kind in ("authored", "derived", "added"):
            results = record.get("results", {}).get(kind, [])
            if not results:
                continue
            tile = sum(1 for r in results if r.get("grid") == "tile")
            nav = sum(1 for r in results if r.get("nav") == "ok")
            floor = sum(1 for r in results if r.get("floor_dz") is not None and abs(r["floor_dz"]) <= 50)
            counts.append("%s %d: tile %d, nav %d, floor %d" % (kind, len(results), tile, nav, floor))
            for result in results:
                if kind != "authored" and (result.get("grid") != "tile" or result.get("nav") != "ok"
                                           or result.get("floor_dz") is None or abs(result["floor_dz"]) > 50):
                    point = result.get("point", {})
                    lines.append("    ! %s %s at %.0f/%.0f/%.0f: tile=%s nav=%s floor_dz=%s" % (
                        record.get("key"), result.get("label"), point.get("X", 0), point.get("Y", 0),
                        point.get("Z", 0), result.get("grid"), result.get("nav"), result.get("floor_dz")))
        lines.insert(0, "  %s (%s, t=%ss): %s" % (record.get("key"), record.get("reason"),
                                                   record.get("elapsed"), "; ".join(counts)))
    return lines, squads


def return_to_den(step):
    for _ in range(7):
        status, text = step("campaign reset", timeout=300)
        if status == "ok" or "a save is being written" not in text:
            break
        time.sleep(10)
    if status == "ok":
        step("wait phase=hub settled=1 timeout=240000", required=True)
    return status, text


def cmd_send(args):
    instance = Instance(args.instance)
    status, text = session(instance).send(args.line, args.timeout)
    print("%s | %s" % (status, text))


def cmd_check(args):
    instance = Instance(args.instance)
    if instance.number == 1 and not args.allow_main:
        sys.exit("Instance 1 is the main install; use a copy (--instance 2) or pass --allow-main.")
    marker = instance.mods / RUNTIME_MOD / "installed_from.txt"
    if not marker.exists():
        sys.exit("Squad Six isn't installed on instance %d: run `install` with the game closed." % instance.number)
    squad = [name.strip() for name in args.squad.split(",") if name.strip()]
    if len(squad) != 6:
        print("note: --squad has %d operators, not six" % len(squad))
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out = ROOT / "dist" / "sandbox" / ("%s-i%d" % (stamp, instance.number))
    out.mkdir(parents=True, exist_ok=True)
    transcript = open(out / "transcript.log", "w")
    sandbox = session(instance, transcript)
    dumps_before = instance.crash_dumps()
    probe_results = instance.probe / "squadsix_probe.jsonl"
    report = ["# Squad Six sandbox check, instance %d, %s" % (instance.number, stamp), "",
              "- installed: %s" % marker.read_text().strip(),
              "- squad: %s" % ", ".join(squad),
              "- observe: %ds per deployment" % args.observe, ""]
    stopped = None

    def step(line, timeout=None, required=False):
        status, text = sandbox.send(line, timeout)
        print("  %s -> %s | %s" % (line, status, text))
        if required and status != "ok":
            raise SandboxError("%s: %s | %s" % (line, status, text))
        return status, text

    if not args.no_baseline:
        # Every check starts from the sandbox campaign's baseline Den (this also works from the main
        # menu), as Off Duty's simtest does.
        try:
            status, text = sandbox.send("campaign load baseline", timeout=300)
            print("campaign load baseline -> %s | %s" % (status, text))
            if status != "ok":
                sys.exit("Couldn't load the sandbox baseline: %s | %s" % (status, text))
        except SandboxError as error:
            sys.exit(str(error))
        report.append("- started from the sandbox baseline Den")

    for spec in args.missions.split(","):
        name, advance = parse_spec(spec.strip())
        print("== %s%s" % (name, " (advance %d)" % advance if advance else ""))
        section = ["## %s" % name, ""]
        log_offset, probe_offset = size_of(instance.ue4ss_log), size_of(probe_results)
        observe_ms = args.observe * 1000
        try:
            step("wait phase=hub settled=1 timeout=240000", required=True)
            # Quoted: the sandbox splits values on spaces, and roster names have them.
            launch = 'mission launch %s squad="%s"' % (name, ",".join(squad))
            if args.enemies:
                launch += " enemies=%s" % args.enemies
            status, text = step(launch + " timeout=120000")
            section.append("- launch: %s | %s" % (status, text))
            if status == "ok":
                step("wait phase=mission settled=1 timeout=240000", required=True)
                # GetAllActorsOfClass includes Blueprint subclasses, unlike the probe's FindAllOf.
                status, text = step("actors /Script/BitReactorGame.AutoGridVolume 5")
                section.append("- grid volumes (actors): %s | %s" % (status, text))
                step("wait ms=%d timeout=%d" % (observe_ms, observe_ms + 30000))
                step("console squadsixprobe")
                for round_number in range(advance):
                    status, text = step("kill foes wait=1 timeout=60000")
                    section.append("- advance %d: kill foes -> %s | %s" % (round_number + 1, status, text))
                    step("wait ms=%d timeout=%d" % (observe_ms, observe_ms + 30000))
                    step("console squadsixprobe")
            # Back to the baseline Den, as Off Duty's simtest does (`mission win` needs a cheat
            # manager the game doesn't always have). Retried while the game is still saving.
            status, text = return_to_den(step)
            section.append("- back to the Den: %s | %s" % (status, text))
        except SandboxError as error:
            section.append("- **stopped: %s**" % error)
            stopped = str(error)
        new_dumps = instance.crash_dumps() - dumps_before
        if new_dumps:
            section.append("- **crash dump: %s**" % ", ".join(sorted(new_dumps)))
            stopped = stopped or "crash"

        text, _ = read_from(instance.ue4ss_log, log_offset)
        ours = [entry for entry in log_entries(text) if any(tag in entry for tag in TAGS)]
        probe_text, _ = read_from(probe_results, probe_offset)
        records = []
        for line in probe_text.splitlines():
            try:
                records.append(json.loads(line))
            except ValueError:
                pass
        lines, squads = probe_summary(records)
        section.append("- squad sizes the probe saw: %s" % (", ".join(map(str, sorted(squads))) or "none"))
        section += ["", "Probe:", ""] + (lines or ["  (no area checks)"])
        key = [l for l in ours if "[SQUAD_SIX_REFORGED]" in l and re.search(
            r"selfcheck|status version|player_destinations|placement_rescue|placement_trigger|"
            r"placement_repair|placement_final|deployment_state|limits|WARNING|ERROR|manual_rescue", l)]
        if not any("placement_trigger" in l for l in key):
            section.append("- no combat preparation in this window (story missions start in exploration)")
        section += ["", "Squad Six:", "", "```"] + (key or ["(no lines)"]) + ["```", ""]
        (out / ("%s.log" % name)).write_text("\n".join(ours) + "\n")
        report += section
        if stopped:
            break

    if stopped:
        report += ["", "**Stopped early: %s.** Crash dumps: %s. Ask the human to restart the game copy, then "
                   "run the remaining missions." % (stopped, instance.crashes)]
    (out / "report.md").write_text("\n".join(report) + "\n")
    transcript.close()
    print("Report: %s" % (out / "report.md"))
    if stopped:
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("install", "uninstall", "status", "info", "check", "send"):
        command = sub.add_parser(name)
        command.add_argument("--instance", type=int, default=2)
        command.add_argument("--allow-main", action="store_true")
        if name == "info":
            command.add_argument("filter", nargs="?", default="")
        if name == "send":
            command.add_argument("line")
            command.add_argument("--timeout", type=float, default=None)
        if name == "check":
            command.add_argument("--missions", required=True,
                                 help="comma-separated mission names; NAME:advance=N also ends N encounters")
            command.add_argument("--squad", required=True, help="six roster names, comma-separated")
            command.add_argument("--enemies", default="", help="an enemy spawn set (sandbox `spawnsets`)")
            command.add_argument("--observe", type=int, default=45, help="seconds to watch each deployment")
            command.add_argument("--no-baseline", action="store_true",
                                 help="don't load the sandbox baseline Den first (use the Den as it is)")
    args = parser.parse_args()
    {"install": cmd_install, "uninstall": cmd_uninstall, "status": cmd_status, "info": cmd_info,
     "check": cmd_check, "send": cmd_send}[args.command](args)


if __name__ == "__main__":
    main()
