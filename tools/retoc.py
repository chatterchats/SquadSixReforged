"""Thin wrapper around retoc (https://github.com/trumank/retoc, 0.1.5) for the Core pak tools."""
from pathlib import Path
import subprocess


class Retoc:
    def __init__(self, binary):
        self.binary = str(binary)

    def run(self, *command):
        result = subprocess.run([self.binary, *map(str, command)], capture_output=True)
        if result.returncode:
            raise RuntimeError(f"retoc {' '.join(map(str, command))} failed:\n"
                               + result.stderr.decode(errors="replace"))
        return result.stdout

    def chunks(self, container):
        """{game path (e.g. /Game/Game/UI/X): chunk id} for every package in a .utoc or directory."""
        found = {}
        for line in self.run("list", "--path", container).decode().splitlines():
            fields = line.split(maxsplit=3)
            if len(fields) == 4 and fields[2] == "ExportBundleData" and game_path(fields[3]):
                found[game_path(fields[3])] = fields[1]
        return found

    def get(self, container, chunk):
        return self.run("get", container, chunk)

    def to_legacy(self, source, output, filter):
        self.run("to-legacy", "--no-shaders", "--no-script-objects", "-f", filter, source, output)

    def to_zen(self, source, utoc):
        # Serial, so the same input always gives the same container bytes.
        self.run("to-zen", "--no-parallel", "--version", "UE5_6", source, utoc)


def game_path(listed):
    """'../../../SWZeroCompany/Content/Game/UI/X.uasset' -> '/Game/Game/UI/X'; None for engine
    and plugin content, which the Core pak never touches."""
    parts = listed.strip().split("SWZeroCompany/Content/", 1)
    return "/Game/" + parts[1].rsplit(".", 1)[0] if len(parts) == 2 else None


def legacy_path(root, path):
    """Where retoc to-legacy writes a package: <root>/SWZeroCompany/Content/<path>.uasset/.uexp."""
    return Path(root) / "SWZeroCompany" / "Content" / path[len("/Game/"):]


def link_base_game(paks, directory):
    """Symlink only the game's own containers (global and *-Windows) into directory, so a
    directory input never picks up installed mods from ~mods."""
    directory.mkdir(parents=True, exist_ok=True)
    linked = 0
    for path in Path(paks).iterdir():
        if path.is_file() and (path.name.startswith("global.") or "-Windows." in path.name):
            (directory / path.name).symlink_to(path.resolve())
            linked += 1
    if not linked:
        raise SystemExit(f"no game containers in {paks}")
    return directory
