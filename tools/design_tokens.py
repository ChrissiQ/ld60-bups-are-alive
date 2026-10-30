"""Reads design/tokens.json (W3C Design Tokens format), the one place the interface's colours, type, radii and spacing are defined.
tools/gen_theme.py builds the game's theme from it; tools/gen_design.py builds docs/design-system.html.
A family's body_height is the em share from the top of its tallest ascender to the bottom of its lowest descender (b d h k l t to g j p q y), measured from the font file.
White is one colour; opacity holds how opaque each use draws it (a border, a hover, a track), and is left off the design page.
load() returns the tokens flattened for those generators: colors (groups of tokens), opacities, typography, radii, borders, icons, spacing."""
import json, os
PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "design", "tokens.json")
EXT = "app.bups"

def _ext(t): return t.get("$extensions", {}).get(EXT, {})

def _lookup(root, ref):
    node = root
    for part in ref.strip("{}").split("."): node = node[part]
    return node

def _rgba(root, t, seen=()):
    v = t["$value"]
    if isinstance(v, str):
        if v in seen: raise ValueError("alias cycle at " + v)
        return _rgba(root, _lookup(root, v), seen + (v,))
    return tuple(v["components"]) + (v.get("alpha", 1),)

def _px(t):
    v = t["$value"]
    if v["unit"] != "px": raise ValueError("tokens are written in px: " + json.dumps(v))
    return v["value"]

def _tokens(group):
    return [(k, v) for k, v in group.items() if not k.startswith("$")]

def load():
    with open(PATH) as f: root = json.load(f)
    colors = []
    for key, g in _tokens(root["color"]):
        toks = []
        for name, t in _tokens(g):
            e = _ext(t)
            alias = t["$value"].strip("{}").split(".")[-1] if isinstance(t["$value"], str) else None
            toks.append({"name": name, "rgba": list(_rgba(root, t)), "role": t["$description"], "use": e.get("use"), "alias": alias})
        colors.append({"group": key.capitalize(), "note": g["$description"], "tokens": toks})
    f = root["font"]
    return {
        "colors": colors,
        "opacities": [{"name": k, "alpha": t["$value"], "role": t["$description"]} for k, t in _tokens(root["opacity"])],
        "typography": {
            "families": [{"id": k, "name": t["$value"][0], "role": t["$description"], "body_height": _ext(t)["body_height"]} for k, t in _tokens(f["family"])],
            "weights": [dict({"name": k, "family": _ext(t)["family"], "weight": t["$value"], "file": _ext(t)["file"], "role": t["$description"]}, **({"uid": _ext(t)["uid"]} if "uid" in _ext(t) else {})) for k, t in _tokens(f["weight"])],
            "sizes": [{"name": k, "px": _px(t), "role": t["$description"]} for k, t in _tokens(f["size"])],
        },
        "radii": [{"name": k, "px": _px(t), "role": t["$description"]} for k, t in _tokens(root["radius"])],
        "borders": [{"name": k, "px": _px(t), "role": t["$description"]} for k, t in _tokens(root["border"])],
        "icons": [{"name": k, "px": _px(t), "theme": _ext(t)["theme"], "role": t["$description"]} for k, t in _tokens(root["icon"])],
        "spacing": [{"name": k, "px": _px(t), "theme": _ext(t)["theme"], "role": t["$description"]} for k, t in _tokens(root["spacing"])],
    }

def colors(data):
    """name -> (r, g, b, a), each 0-1; each opacity is white at that alpha."""
    out = {}
    for g in data["colors"]:
        for t in g["tokens"]:
            if t["name"] in out: raise ValueError("duplicate token " + t["name"])
            out[t["name"]] = tuple(t["rgba"])
    white = out["white"][:3]
    for o in data["opacities"]:
        if o["name"] in out: raise ValueError("duplicate token " + o["name"])
        out[o["name"]] = white + (o["alpha"],)
    return out

def hexcode(c):
    """#rrggbb, or #rrggbbaa when translucent."""
    v = [round(x * 255) for x in c]
    return "#%02x%02x%02x" % tuple(v[:3]) + ("" if v[3] == 255 else "%02x" % v[3])
