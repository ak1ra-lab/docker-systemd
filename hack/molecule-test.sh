#!/usr/bin/env bash
# Run the Ansible-native Molecule scenario against the matrix images.
#
# The scenario uses the containers.podman connection plugin, so Podman is
# required. Run this as a normal user for rootless Podman, or as root for
# rootful Podman (which is what CI does for reliability).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
cd "$ROOT_DIR"

usage() {
    cat <<'EOF'
Usage: hack/molecule-test.sh [--build] [-- molecule options]

Options:
  --build    Build every matrix image with Podman before testing
  -h, --help Show this help

Environment:
  JOBS       Parallel builds when --build is used (default: 4)

Examples:
  hack/molecule-test.sh --build
  hack/molecule-test.sh -- -v
EOF
}

build=false
while (($# > 0)); do
    case "$1" in
    --build)
        build=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    --)
        shift
        break
        ;;
    *)
        break
        ;;
    esac
done

if ! command -v molecule >/dev/null 2>&1; then
    printf 'molecule is not installed; run "make venv" and activate .venv, or use "make molecule"\n' >&2
    exit 1
fi

if [[ $build == true ]]; then
    "${ROOT_DIR}/hack/build.sh" --all --runtime podman --jobs "${JOBS:-4}"
fi

exec molecule test -s systemd "$@"
