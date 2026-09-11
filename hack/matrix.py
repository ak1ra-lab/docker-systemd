#!/usr/bin/env python3
"""Emit the image matrix in formats consumed by scripts and CI."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
MATRIX_FILE = ROOT / "matrix.yaml"

RUNNERS = {
    "amd64": "ubuntu-24.04",
    "arm64": "ubuntu-24.04-arm",
}

Matrix = dict[str, Any]


class MatrixError(Exception):
    """Raised when matrix.yaml cannot produce a valid CI matrix."""


def load_matrix() -> Matrix:
    try:
        with MATRIX_FILE.open(encoding="utf-8") as handle:
            matrix = yaml.safe_load(handle)
    except yaml.YAMLError as exc:
        raise MatrixError(f"{MATRIX_FILE.name} is not valid YAML: {exc}") from exc
    if not isinstance(matrix, dict):
        raise MatrixError(f"{MATRIX_FILE.name} must contain a YAML mapping")
    return matrix


def image_name(matrix: Matrix, distro: str, version: str) -> str:
    registry = matrix["registry"]
    return f"{registry['host']}/{registry['namespace']}/{distro}:{version}"


def tags_for(matrix: Matrix, distro: str, version_meta: Matrix) -> list[str]:
    version = version_meta["version"]
    tags = [image_name(matrix, distro, version)]
    registry = matrix["registry"]
    for alias in version_meta.get("aliases", []):
        tags.append(f"{registry['host']}/{registry['namespace']}/{distro}:{alias}")
    return tags


def entries(matrix: Matrix) -> list[dict[str, Any]]:
    result = []
    for distro, distro_meta in matrix["distros"].items():
        for version_meta in distro_meta["versions"]:
            version = version_meta["version"]
            result.append(
                {
                    "distro": distro,
                    "version": version,
                    "display_name": distro_meta["display_name"],
                    "base_image": version_meta["base_image"],
                    "image": image_name(matrix, distro, version),
                    "dockerfile": f"images/{distro}/{version}/Dockerfile",
                    "context": f"images/{distro}/{version}",
                    "eol": version_meta["eol"],
                    "tags": tags_for(matrix, distro, version_meta),
                }
            )
    return result


def runner_for(arch: str) -> str:
    try:
        return RUNNERS[arch]
    except KeyError:
        known = ", ".join(sorted(RUNNERS))
        raise MatrixError(
            f"no GitHub runner known for architecture {arch!r} (known: {known})"
        ) from None


def github_build_matrix(matrix: Matrix) -> str:
    include = []
    for entry in entries(matrix):
        for arch in matrix["defaults"]["architectures"]:
            include.append(
                {
                    "distro": entry["distro"],
                    "version": entry["version"],
                    "arch": arch,
                    "runs_on": runner_for(arch),
                    "image": entry["image"],
                    "dockerfile": entry["dockerfile"],
                    "context": entry["context"],
                }
            )
    return json.dumps({"include": include})


def github_publish_matrix(matrix: Matrix) -> str:
    include = []
    for entry in entries(matrix):
        include.append(
            {
                "distro": entry["distro"],
                "version": entry["version"],
                "image": entry["image"],
                "dockerfile": entry["dockerfile"],
                "context": entry["context"],
                "tags": "\n".join(entry["tags"]),
            }
        )
    return json.dumps({"include": include})


def tsv(matrix: Matrix) -> str:
    lines = []
    for entry in entries(matrix):
        lines.append(
            "\t".join(
                [
                    entry["distro"],
                    entry["version"],
                    entry["image"],
                    entry["dockerfile"],
                    entry["context"],
                    ",".join(entry["tags"]),
                ]
            )
        )
    return "\n".join(lines)


def json_matrix(matrix: Matrix) -> str:
    return json.dumps(entries(matrix), indent=2)


FORMATTERS = {
    "github-build": github_build_matrix,
    "github-publish": github_publish_matrix,
    "tsv": tsv,
    "json": json_matrix,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=FORMATTERS, default="json")
    args = parser.parse_args()

    try:
        matrix = load_matrix()
        output = FORMATTERS[args.format](matrix)
    except MatrixError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
