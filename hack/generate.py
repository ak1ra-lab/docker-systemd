#!/usr/bin/env python3
"""Generate derived files from matrix.yaml.

Generated outputs are committed to the repository so they can be reviewed as
ordinary files:

  - images/<distro>/<version>/Dockerfile
  - molecule/systemd/inventory/hosts.yml
  - the distribution table in README.md

Run with --check in CI to fail when a generated file is stale.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined
from yaml.constructor import ConstructorError
from yaml.nodes import MappingNode

ROOT = Path(__file__).resolve().parent.parent
MATRIX_FILE = ROOT / "matrix.yaml"
TEMPLATES_DIR = ROOT / "templates"
IMAGES_DIR = ROOT / "images"
MOLECULE_INVENTORY = ROOT / "molecule" / "systemd" / "inventory" / "hosts.yml"
README_FILE = ROOT / "README.md"

BEGIN_MARKER = "<!-- BEGIN GENERATED MATRIX -->"
END_MARKER = "<!-- END GENERATED MATRIX -->"

REQUIRED_SECTIONS = ("project", "registry", "defaults", "families", "distros")

Matrix = dict[str, Any]
Outputs = dict[Path, str]


class MatrixError(Exception):
    """Raised when matrix.yaml is missing data or internally inconsistent."""


class _UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that rejects duplicate mapping keys instead of last-wins."""

    def construct_mapping(self, node: MappingNode, deep: bool = False) -> Matrix:
        self.flatten_mapping(node)
        seen: set[Any] = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise ConstructorError(
                    "while constructing a mapping",
                    node.start_mark,
                    f"found duplicate key {key!r}",
                    key_node.start_mark,
                )
            seen.add(key)
        return super().construct_mapping(node, deep=deep)


def _require_mapping(value: Any, where: str) -> Matrix:
    if not isinstance(value, dict):
        raise MatrixError(f"{where} must be a mapping")
    return value


def _require_key(mapping: Matrix, key: str, where: str) -> Any:
    if key not in mapping:
        raise MatrixError(f"{where} is missing the required key '{key}'")
    return mapping[key]


def _require_list(value: Any, where: str) -> list[Any]:
    if not isinstance(value, list):
        raise MatrixError(f"{where} must be a list")
    return value


def validate_matrix(matrix: Any) -> None:
    """Fail fast with a clear message when matrix.yaml is malformed."""
    matrix = _require_mapping(matrix, "matrix.yaml")
    for section in REQUIRED_SECTIONS:
        _require_key(matrix, section, "matrix.yaml")

    registry = _require_mapping(matrix["registry"], "registry")
    _require_key(registry, "host", "registry")
    _require_key(registry, "namespace", "registry")

    defaults = _require_mapping(matrix["defaults"], "defaults")
    _require_key(defaults, "init_path", "defaults")
    _require_key(defaults, "stop_signal", "defaults")

    families = _require_mapping(matrix["families"], "families")
    for name, family in families.items():
        where = f"families.{name}"
        family = _require_mapping(family, where)
        template = _require_key(family, "template", where)
        if not (TEMPLATES_DIR / template).is_file():
            raise MatrixError(f"{where}.template does not exist: {template}")
        _require_list(_require_key(family, "packages", where), f"{where}.packages")
        _require_list(family.get("enable_units", []), f"{where}.enable_units")

    distros = _require_mapping(matrix["distros"], "distros")
    for distro, distro_meta in distros.items():
        where = f"distros.{distro}"
        distro_meta = _require_mapping(distro_meta, where)
        _require_key(distro_meta, "display_name", where)
        family_name = _require_key(distro_meta, "family", where)
        if family_name not in families:
            raise MatrixError(f"{where}.family does not exist: {family_name}")
        versions = _require_list(
            _require_key(distro_meta, "versions", where), f"{where}.versions"
        )
        if not versions:
            raise MatrixError(f"{where}.versions must not be empty")
        seen_versions: set[str] = set()
        seen_aliases: set[str] = set()
        for index, version_meta in enumerate(versions):
            vwhere = f"{where}.versions[{index}]"
            version_meta = _require_mapping(version_meta, vwhere)
            version = _require_key(version_meta, "version", vwhere)
            if version in seen_versions:
                raise MatrixError(f"{where} lists version {version!r} twice")
            seen_versions.add(version)
            _require_key(version_meta, "base_image", vwhere)
            _require_key(version_meta, "eol", vwhere)
            aliases = _require_list(
                version_meta.get("aliases", []), f"{vwhere}.aliases"
            )
            for alias in aliases:
                if alias in seen_aliases:
                    raise MatrixError(f"{where} assigns alias {alias!r} twice")
                seen_aliases.add(alias)


def load_matrix() -> Matrix:
    with MATRIX_FILE.open(encoding="utf-8") as handle:
        loader = _UniqueKeyLoader(handle)
        try:
            matrix = loader.get_single_data()
        except yaml.YAMLError as exc:
            raise MatrixError(f"{MATRIX_FILE.name} is not valid YAML: {exc}") from exc
        finally:
            loader.dispose()
    validate_matrix(matrix)
    return matrix


def image_name(matrix: Matrix, distro: str, version: str) -> str:
    registry = matrix["registry"]
    return f"{registry['host']}/{registry['namespace']}/{distro}:{version}"


def host_name(distro: str, version: str) -> str:
    return f"{distro}-{version.replace('.', '')}"


def family_for(matrix: Matrix, distro: str) -> Matrix:
    return matrix["families"][matrix["distros"][distro]["family"]]


def packages_for(distro: str, family: Matrix, version_meta: Matrix) -> list[str]:
    packages = list(family["packages"])
    packages.extend(version_meta.get("packages_add", []))
    for package in version_meta.get("packages_remove", []):
        if package not in packages:
            raise MatrixError(
                f"{distro} {version_meta['version']} removes package {package!r} "
                "that the family does not install"
            )
        packages.remove(package)
    return packages


def packages_block(packages: list[str]) -> str:
    return "\n".join(f"        {package} \\" for package in packages)


def post_install_block(enable_units: list[str]) -> str:
    if not enable_units:
        return ""
    return "\nRUN systemctl enable " + " ".join(enable_units) + "\n"


def hosts_block(hosts: dict[str, str]) -> str:
    lines = []
    for host, image in hosts.items():
        lines.append(f"        {host}:")
        lines.append(f"          container_image: {image}")
    return "\n".join(lines)


def render_dockerfiles(matrix: Matrix, env: Environment) -> Outputs:
    outputs: Outputs = {}
    for distro, distro_meta in matrix["distros"].items():
        family = family_for(matrix, distro)
        template = env.get_template(family["template"])
        for version_meta in distro_meta["versions"]:
            version = version_meta["version"]
            codename = version_meta.get("codename", "")
            title = f"{distro_meta['display_name']} {version}"
            if codename:
                title += f" ({codename})"
            outputs[IMAGES_DIR / distro / version / "Dockerfile"] = template.render(
                base_image=version_meta["base_image"],
                distro=distro,
                version=version,
                codename=codename,
                title=title,
                project=matrix["project"],
                packages_block=packages_block(
                    packages_for(distro, family, version_meta)
                ),
                post_install_block=post_install_block(family.get("enable_units", [])),
                init_path=matrix["defaults"]["init_path"],
                stop_signal=matrix["defaults"]["stop_signal"],
            )
    return outputs


def render_inventory(matrix: Matrix, env: Environment) -> Outputs:
    hosts: dict[str, str] = {}
    for distro, distro_meta in matrix["distros"].items():
        for version_meta in distro_meta["versions"]:
            version = version_meta["version"]
            hosts[host_name(distro, version)] = image_name(matrix, distro, version)
    template = env.get_template("molecule-hosts.yml.j2")
    return {MOLECULE_INVENTORY: template.render(hosts_block=hosts_block(hosts))}


def render_readme_table(matrix: Matrix) -> str:
    lines = [
        "| Distribution | Version | Base image | Aliases | Upstream EOL | Image |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for distro, distro_meta in matrix["distros"].items():
        for version_meta in distro_meta["versions"]:
            version = version_meta["version"]
            version_label = version
            if version_meta.get("codename"):
                version_label += f" ({version_meta['codename']})"
            aliases = ", ".join(
                f"`{alias}`" for alias in version_meta.get("aliases", [])
            )
            lines.append(
                f"| {distro_meta['display_name']} | {version_label} "
                f"| `{version_meta['base_image']}` | {aliases or '-'} "
                f"| {version_meta['eol']} | `{image_name(matrix, distro, version)}` |"
            )
    return "\n".join(lines)


def render_readme(matrix: Matrix) -> Outputs:
    original = README_FILE.read_text(encoding="utf-8")
    begin = original.find(BEGIN_MARKER)
    end = original.find(END_MARKER)
    if begin == -1 or end == -1:
        raise MatrixError(f"README.md must contain {BEGIN_MARKER} and {END_MARKER}")
    if end < begin:
        raise MatrixError(f"README.md has {END_MARKER} before {BEGIN_MARKER}")
    before = original[:begin]
    after = original[end + len(END_MARKER) :]
    content = (
        f"{before}{BEGIN_MARKER}\n{render_readme_table(matrix)}\n{END_MARKER}{after}"
    )
    return {README_FILE: content}


def build_outputs(matrix: Matrix, env: Environment) -> Outputs:
    outputs: Outputs = {}
    outputs.update(render_dockerfiles(matrix, env))
    outputs.update(render_inventory(matrix, env))
    outputs.update(render_readme(matrix))
    return outputs


def check(outputs: Outputs) -> int:
    failures = 0
    for path, content in sorted(outputs.items()):
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current is None:
            failures += 1
            print(f"missing: {path.relative_to(ROOT)}", file=sys.stderr)
        elif current != content:
            failures += 1
            print(f"stale: {path.relative_to(ROOT)}", file=sys.stderr)
    expected = set(outputs)
    for path in sorted(IMAGES_DIR.glob("*/*/Dockerfile")):
        if path not in expected:
            failures += 1
            print(f"orphan: {path.relative_to(ROOT)}", file=sys.stderr)
    if failures:
        print(
            f"{failures} generated file(s) out of date; "
            "run `python3 hack/generate.py` and commit the result",
            file=sys.stderr,
        )
        return 1
    return 0


def write_outputs(outputs: Outputs) -> None:
    staged: list[tuple[Path, Path]] = []
    try:
        for path, content in sorted(outputs.items()):
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(f".{path.name}.tmp")
            staged.append((temporary, path))
            temporary.write_text(content, encoding="utf-8")
        for temporary, path in staged:
            temporary.replace(path)
            print(f"generated: {path.relative_to(ROOT)}")
    finally:
        for temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="verify generated files are up to date"
    )
    args = parser.parse_args()

    try:
        matrix = load_matrix()
        env = Environment(
            loader=FileSystemLoader(TEMPLATES_DIR),
            undefined=StrictUndefined,
            keep_trailing_newline=True,
        )
        outputs = build_outputs(matrix, env)
    except MatrixError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.check:
        return check(outputs)

    write_outputs(outputs)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
