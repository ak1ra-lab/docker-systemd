#!/usr/bin/env bash
# Build matrix images with Docker or Podman.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
PYTHON=${PYTHON:-python3}

usage() {
    cat <<'EOF'
Usage: hack/build.sh [options] (--all | <distro> <version>)

Build one image or every image in matrix.yaml. Images are tagged with the
fully qualified registry name from matrix.yaml, so the Molecule scenario can
use them without an extra prefix.

Options:
  --runtime docker|podman   Container runtime to use (default: podman)
  --pull                    Always pull the base image
  --jobs N                  Build up to N images in parallel (default: 1)
  --dry-run                 Print what would be built without building
  -h, --help                Show this help

Examples:
  hack/build.sh --all --runtime podman --jobs 4
  hack/build.sh debian 13
EOF
}

runtime=podman
pull=missing
jobs=1
all=false
dry_run=false
distro=""
version=""

while (($# > 0)); do
    case "$1" in
    --runtime)
        runtime=${2:?missing value for --runtime}
        shift 2
        ;;
    --runtime=*)
        runtime=${1#*=}
        shift
        ;;
    --pull)
        pull=always
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
    --all)
        all=true
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
    -*)
        printf 'unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    *)
        if [[ -z $distro ]]; then
            distro=$1
        elif [[ -z $version ]]; then
            version=$1
        else
            printf 'unexpected argument: %s\n' "$1" >&2
            exit 2
        fi
        shift
        ;;
    esac
done

if [[ $runtime != docker && $runtime != podman ]]; then
    printf 'unsupported runtime: %s\n' "$runtime" >&2
    exit 2
fi

if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    printf 'invalid job count: %s\n' "$jobs" >&2
    exit 2
fi

if [[ $all == false && (-z $distro || -z $version) ]]; then
    usage >&2
    exit 2
fi

if [[ $dry_run == false ]] && ! command -v "$runtime" >/dev/null 2>&1; then
    printf 'container runtime not found: %s\n' "$runtime" >&2
    exit 1
fi

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    printf 'python interpreter not found: %s\n' "$PYTHON" >&2
    exit 1
fi

build_one() {
    local entry=$1
    local entry_distro entry_version image dockerfile context
    IFS=$'\t' read -r entry_distro entry_version image dockerfile context _ <<<"$entry"
    printf '==> building %s %s (%s)\n' "$entry_distro" "$entry_version" "$image"
    local args=()
    if [[ $runtime == docker ]]; then
        [[ $pull == always ]] && args+=(--pull)
    else
        args+=("--pull=${pull}")
    fi
    if [[ $dry_run == true ]]; then
        printf '    %s build %s --tag %s --file %s %s\n' \
            "$runtime" "${args[*]}" "$image" "${ROOT_DIR}/${dockerfile}" "${ROOT_DIR}/${context}"
        return 0
    fi
    "$runtime" build "${args[@]}" --tag "$image" --file "${ROOT_DIR}/${dockerfile}" "${ROOT_DIR}/${context}"
}
export -f build_one
export runtime pull ROOT_DIR dry_run

entries=$("$PYTHON" "${ROOT_DIR}/hack/matrix.py" --format tsv)
if [[ $all == false ]]; then
    entries=$(awk -F'\t' -v d="$distro" -v v="$version" '$1 == d && $2 == v' <<<"$entries")
fi

if [[ -z $entries ]]; then
    printf 'no image in matrix.yaml matches the request\n' >&2
    exit 1
fi

count=$(wc -l <<<"$entries")
printf 'building %s image(s) with %s\n' "$count" "$runtime"
printf '%s\n' "$entries" | xargs -d '\n' -P "$jobs" -I '{}' bash -c 'build_one "$@"' _ '{}'
printf 'built %s image(s)\n' "$count"
