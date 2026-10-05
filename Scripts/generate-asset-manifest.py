#!/usr/bin/env python3
"""Create the Swift asset URLs and application-layout tags from the pinned Rails assets."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "reference"
OUTPUT = ROOT / "Sources" / "CampfireCore" / "GeneratedAssetManifest.swift"

# Rust owns these rendered overrides; their digests come from its parity-tested Propshaft build.
OVERRIDES = {
    "flash.css": "/assets/flash-a561c1e5.css",
    "layout.css": "/assets/layout-ff6ddfc6.css",
    "sidebar.css": "/assets/sidebar-0be58db9.css",
}
RAILS_GEM_STYLESHEETS = (
    "_reset.css", "actiontext.css", "animation.css", "autocomplete.css", "avatars.css", "base.css",
    "boosts.css", "buttons.css", "code.css", "colorize.css", "colors.css", "composer.css", "embeds.css",
    "filters.css", "inputs.css", "lexxy-content.css", "lexxy-editor.css", "lexxy-variables.css", "lexxy.css",
    "lightbox.css", "messages.css", "nav.css", "panels.css", "separators.css", "signup.css", "spinner.css", "trix.css",
    "utilities.css",
)
LOAD_PATHS = [
    (REFERENCE / "app/assets/stylesheets", "flat"),
    (REFERENCE / "app/assets/images", "flat"),
    (REFERENCE / "app/assets/sounds", "flat"),
    (REFERENCE / "app/javascript", "nested"),
    (REFERENCE / "vendor/javascript", "nested"),
]

# A source checkout can be built without the reference submodule. Keep the checked-in manifest
# (which is the documented fallback) intact until its source assets or import map are available.
if not (REFERENCE / "config/importmap.rb").is_file() and not any(path.exists() for path, _ in LOAD_PATHS):
    print("reference assets are absent; using the checked-in asset manifest")
    raise SystemExit(0)

paths: dict[str, str] = {}
for load_path, shape in LOAD_PATHS:
    for asset in sorted(load_path.rglob("*")) if load_path.exists() else []:
        if not asset.is_file() or asset.name.startswith("."):
            continue
        logical = asset.relative_to(load_path).as_posix() if shape == "nested" else asset.name
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()[:8]
        asset_name = logical if shape == "nested" else asset.name
        asset_path = Path(asset_name)
        paths.setdefault(logical, f"/assets/{asset_path.with_suffix('')}-{digest}{asset.suffix}")

# The Rails build manifest wins for compiled assets; Rust's render-owned paths win last.
rails_manifest = REFERENCE / "public/assets/.manifest.json"
if rails_manifest.exists():
    for logical, entry in json.loads(rails_manifest.read_text()).items():
        digest_path = entry.get("digested_path") if isinstance(entry, dict) else entry
        if digest_path:
            paths[logical] = f"/assets/{digest_path.lstrip('/')}"
paths.update(OVERRIDES)

# Propshaft includes CSS from Rails engine load paths (Action Text and Lexxy) as well as the
# application's own assets. Those gems are resolved by Bundler at runtime, not stored in the
# reference submodule; only their logical stylesheet names are needed by the HTML renderer.
for logical in RAILS_GEM_STYLESHEETS:
    paths.setdefault(logical, f"/assets/{Path(logical).stem}-00000000.css")

stylesheet_tags = "\n".join(
    f'<link rel="stylesheet" href="{paths[logical]}" data-turbo-track="reload" />'
    for logical in sorted(path for path in paths if path.endswith(".css"))
)


def importmap_pins() -> list[tuple[str, str, bool]]:
    pins: list[tuple[str, str, bool]] = []
    config = REFERENCE / "config/importmap.rb"
    if not config.exists():
        return pins
    for line in config.read_text().splitlines():
        pin = re.match(r'\s*pin\s+"([^"]+)"(?:,\s*to:\s*"([^"]+)")?(.*)', line)
        if pin:
            name, target, options = pin.groups()
            pins.append((name, target or f"{name}.js", not re.search(r"preload:\s*false", options)))
            continue
        group = re.match(r'\s*pin_all_from\s+"([^"]+)"(?:,\s*under:\s*"([^"]+)")?(.*)', line)
        if not group:
            continue
        source, namespace, options = group.groups()
        source_dir = REFERENCE / source
        if not source_dir.is_dir():
            continue
        for asset in sorted(source_dir.rglob("*.js")):
            relative = asset.relative_to(source_dir).with_suffix("").as_posix()
            name = namespace if relative == "index" and namespace else "/".join(part for part in (namespace, relative) if part)
            if source.startswith("app/"):
                target = asset.relative_to(REFERENCE / "app").as_posix().split("/", 1)[1]
            else:
                target = asset.relative_to(REFERENCE / "vendor").as_posix().split("/", 1)[1]
            pins.append((name, target, not re.search(r"preload:\s*false", options)))
    return pins


pins = importmap_pins()
for _, target, _ in pins:
    if target not in paths:
        path = Path(target)
        paths[target] = f"/assets/{path.with_suffix('')}-00000000{path.suffix}"
imports = [(name, paths[target]) for name, target, _ in pins]
if imports:
    import_lines = ",\n".join(f"    {json.dumps(name)}: {json.dumps(path)}" for name, path in imports)
    importmap_json = "{\n  \"imports\": {\n" + import_lines + "\n  }\n}"
else:
    importmap_json = "{\n  \"imports\": {}\n}"
preloads: list[str] = []
for _, target, preload in pins:
    path = paths.get(target)
    if preload and path and path not in preloads:
        preloads.append(path)
importmap_tags = (
    f'<script type="importmap" data-turbo-track="reload">{importmap_json}</script>\n'
    + "\n".join(f'<link rel="modulepreload" href="{path}">' for path in preloads)
    + '\n<script type="module">import "application"</script>'
)

entries = ",\n".join(f"        {json.dumps(key)}: {json.dumps(value)}" for key, value in sorted(paths.items()))
OUTPUT.write_text(
    "// Generated by Scripts/generate-asset-manifest.py.\n"
    "enum GeneratedAssetManifest {\n"
    "    static let paths: [String: String] = [\n"
    f"{entries}\n"
    "    ]\n"
    f"    static let stylesheetTags = {json.dumps(stylesheet_tags, ensure_ascii=False)}\n"
    f"    static let importmapTags = {json.dumps(importmap_tags, ensure_ascii=False)}\n"
    "}\n"
)
