"""Build the current Squad Six Reforged v2 release from verified committed cooked assets.
The historical v1 packager is retained as tools/package_v1.py.
"""
from package_v2 import ROOT, build
import json

if __name__ == "__main__":
    build(json.loads((ROOT / "release.json").read_text())["version"], True)
