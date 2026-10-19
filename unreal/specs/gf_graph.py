"""Graph building for the Game Feature trial's ZComAuthoring specs (gf.py, gf_lineup.py)."""

KSL = "/Script/Engine.KismetSystemLibrary"
KML = "/Script/Engine.KismetMathLibrary"
KAL = "/Script/Engine.KismetArrayLibrary"
GS = "/Script/Engine.GameplayStatics"
TARGET = 6


class Graph:
    def __init__(self):
        self.nodes, self.links = [], []

    def node(self, id, kind, defaults=None, **fields):
        spec = {"id": id, "kind": kind, **fields}
        if defaults:
            spec["defaults"] = {k: str(v) for k, v in defaults.items()}
        self.nodes.append(spec)
        return id

    def call(self, id, function, defaults=None):
        return self.node(id, "call", defaults, function=function)

    def link(self, a, b):
        self.links.append([a, b])

    def wire(self, *pairs):
        for a, b in pairs:
            self.link(a, b)

    def chain(self, *steps):
        """Exec chain: each step is 'node' (then -> execute) or 'node.pin' for a named output."""
        for a, b in zip(steps, steps[1:]):
            self.link(a if "." in a else f"{a}.then", f"{b}.execute" if "." not in b else b)

    def spec(self):
        return {"nodes": self.nodes, "links": self.links}
