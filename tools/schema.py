"""Extract the property schemas a mission definition needs from a parsed .usmap.

  python3 tools/schema.py <usmap dir with schemas.tsv and properties.tsv> [--root BrunoMissionData]
  python3 tools/schema.py <usmap dir> --output tools/data/map_schema.json \
      --root BP_CombatPreparationArea_C --root TacticalPoint --root SphereComponent

Writes tools/data/schema.json (or --output): every class and struct reachable from the roots (through
supers and struct-typed properties), with its super, struct flags and properties in
serialization order. Regenerate it from a fresh usmap after a game patch that changes these
classes; zen.read_properties fails loudly when the schema no longer matches the data.
"""
from pathlib import Path
import argparse
import csv
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "tools" / "data" / "schema.json"

parser = argparse.ArgumentParser()
parser.add_argument("usmap", type=Path)
parser.add_argument("--root", action="append", default=None)
parser.add_argument("--output", type=Path, default=OUTPUT)
args = parser.parse_args()
roots = args.root or ["BrunoMissionData"]

csv.field_size_limit(sys.maxsize)


def rows(name):
    with open(args.usmap / name, newline="") as handle:
        return list(csv.DictReader(handle, delimiter="\t"))


by_index, by_name = {}, {}
for row in rows("schemas.tsv"):
    by_index[row["schema_index"]] = {"name": row["name"], "super": row["super"] or None,
                                     "flags": int(row["struct_flags"]), "module": row["module_path"],
                                     "properties": []}
    by_name.setdefault(row["name"], []).append(row["schema_index"])
for row in rows("properties.tsv"):
    by_index[row["schema_index"]]["properties"].append({
        "index": int(row["property_index"]),
        "name": row["name"],
        "array_dim": int(row["array_dim"]),
        "type": json.loads(row["type_json"]),
    })


def lookup(name):
    """Schemas are referenced by bare name; a name used by two modules can't be resolved."""
    indices = by_name.get(name)
    if not indices:
        raise SystemExit(f"no schema named {name}")
    if len(indices) > 1:
        modules = [by_index[i]["module"] for i in indices]
        raise SystemExit(f"{name} is defined in several modules ({', '.join(modules)})")
    return by_index[indices[0]]


def referenced(type_info):
    if type_info.get("type") == "StructProperty":
        yield type_info["struct"]
    for key in ("inner", "key", "value"):
        if key in type_info:
            yield from referenced(type_info[key])


wanted, pending = {}, list(roots)
while pending:
    name = pending.pop()
    if name in wanted or name is None:
        continue
    entry = lookup(name)
    entry["properties"].sort(key=lambda prop: prop["index"])
    assert [prop["index"] for prop in entry["properties"]] == list(range(len(entry["properties"]))), name
    wanted[name] = {key: value for key, value in entry.items() if key != "name"}
    pending.append(entry["super"])
    for prop in entry["properties"]:
        pending.extend(referenced(prop["type"]))

output = args.output.resolve()
output.parent.mkdir(exist_ok=True)
output.write_text(json.dumps({"roots": roots, "schemas": dict(sorted(wanted.items()))}, indent=1) + "\n")
print(f"Wrote {len(wanted)} schemas reachable from {', '.join(roots)} to {output.relative_to(ROOT)}")
