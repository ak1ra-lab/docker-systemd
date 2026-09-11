#!/usr/bin/env bash
# Rebuild the matrix images from the GitHub Actions build cache and load them
# into Podman.
#
# GitHub Actions only: the cache backend reads the Actions cache environment
# that every job provides. The build-smoke jobs write every layer to that cache
# with `cache-to: type=gha,mode=max`, so rebuilding here takes seconds per
# image instead of a cold Podman build.
#
# Images are loaded into rootful Podman (via sudo when not run as root)
# because that is how hack/molecule-test.sh runs the scenario in CI. Loads are
# serialized because Podman does not like concurrent writers to its storage.
#
# Usage: hack/ci-load-images.sh [options]
#
# Options:
#   --arch ARCH  Architecture to build and load (default: amd64)
#   --jobs N     Build up to N images in parallel (default: 4)
#   --dry-run    Print the build commands without running them
#   -h, --help   Show this help
#
# Environment:
#   PYTHON  Python interpreter used for hack/matrix.py (default: python3)
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
PYTHON=${PYTHON:-python3}

usage() {
    cat <<'EOF'
Usage: hack/ci-load-images.sh [options]

Rebuild every image in matrix.yaml from the GitHub Actions build cache and
load it into Podman. Only usable inside GitHub Actions.

Options:
  --arch ARCH  Architecture to build and load (default: amd64)
  --jobs N     Build up to N images in parallel (default: 4)
  --dry-run    Print the build commands without running them
  -h, --help   Show this help

Environment:
  PYTHON       Python interpreter used for hack/matrix.py (default: python3)
EOF
}

arch=amd64
jobs=4
dry_run=false

while (($# > 0)); do
    case "$1" in
    --arch)
        arch=${2:?missing value for --arch}
        shift 2
        ;;
    --arch=*)
        arch=${1#*=}
        shift
        ;;
    --jobs)
        jobs=${2:?missing value for --jobs}
        shift 2
        ;;
    --jobs=*)
        jobs=${1#*=}
        shift
        ;;
    --dry-run)
        dry_run=true
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

if [[ -z $arch ]]; then
    printf 'empty architecture\n' >&2
    exit 2
fi

if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    printf 'invalid job count: %s\n' "$jobs" >&2
    exit 2
fi

if [[ $dry_run == false ]]; then
    if ! command -v docker >/dev/null 2>&1 || ! docker buildx version >/dev/null 2>&1; then
        printf 'docker buildx is required to build from the GitHub Actions cache\n' >&2
        exit 1
    fi
    if ! command -v podman >/dev/null 2>&1; then
        printf 'podman is required to load the images\n' >&2
        exit 1
    fi
    if ! command -v flock >/dev/null 2>&1; then
        printf 'flock is required to serialize the podman loads\n' >&2
        exit 1
    fi
    if ((EUID != 0)) && ! command -v sudo >/dev/null 2>&1; then
        printf 'run as root or install sudo to load images into rootful Podman\n' >&2
        exit 1
    fi
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

entries=$("$PYTHON" "${ROOT_DIR}/hack/matrix.py" --format tsv)
if [[ -z $entries ]]; then
    printf 'no images found in matrix.yaml\n' >&2
    exit 1
fi
count=$(wc -l <<<"$entries")

if [[ $dry_run == true ]]; then
    while IFS=$'\t' read -r distro version image dockerfile context _; do
        [[ -n $distro ]] || continue
        printf 'docker buildx build --file %s --tag %s --platform linux/%s --pull --cache-from type=gha,scope=%s-%s-%s --output type=docker,dest=%s/%s-%s.tar %s\n' \
            "${ROOT_DIR}/${dockerfile}" "$image" "$arch" \
            "$distro" "$version" "$arch" "$work_dir" "$distro" "$version" \
            "${ROOT_DIR}/${context}"
    done <<<"$entries"
    exit 0
fi

build_one() {
    local entry=$1
    local entry_distro entry_version image dockerfile context
    IFS=$'\t' read -r entry_distro entry_version image dockerfile context _ <<<"$entry"
    local archive="${work_dir}/${entry_distro}-${entry_version}.tar"
    printf '==> building %s %s\n' "$entry_distro" "$entry_version"
    docker buildx build \
        --file "${ROOT_DIR}/${dockerfile}" \
        --tag "$image" \
        --platform "linux/${arch}" \
        --pull \
        --cache-from "type=gha,scope=${entry_distro}-${entry_version}-${arch}" \
        --output "type=docker,dest=${archive}" \
        "${ROOT_DIR}/${context}"
    printf '==> loading %s\n' "$image"
    (
        flock 9
        if ((EUID == 0)); then
            podman load --input "$archive"
        else
            sudo podman load --input "$archive"
        fi
    ) 9>"${work_dir}/podman-load.lock"
    rm -f "$archive"
}
export -f build_one
export ROOT_DIR work_dir arch

printf 'building %s image(s) from the GitHub Actions cache (arch=%s, jobs=%s)\n' \
    "$count" "$arch" "$jobs"
printf '%s\n' "$entries" |
    xargs -d '\n' -P "$jobs" -I '{}' bash -c 'set -euo pipefail; build_one "$@"' _ '{}'

printf 'loaded %s image(s) into podman\n' "$count"
