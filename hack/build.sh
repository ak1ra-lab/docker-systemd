#!/usr/bin/env bash
# Build matrix images with Docker or Podman.
set -o errexit -o nounset -o errtrace

SCRIPT_FILE="$(readlink -f "${0}")"
SCRIPT_NAME="$(basename "${SCRIPT_FILE}")"

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
PYTHON=${PYTHON:-python3}

runtime=podman
pull=missing
jobs=1
all=false
dry_run=false
distro=""
version=""

usage() {
    local exit_code="${1:-0}"
    cat <<EOF
Usage: ${SCRIPT_NAME} [options] (--all | <distro> <version>)

Build one image or every image in matrix.yaml. Images are tagged with the
fully qualified registry name from matrix.yaml, so the Molecule scenario can
use them without an extra prefix.

Options:
  -h, --help                Show this help
  --runtime docker|podman   Container runtime to use (default: podman)
  --pull                    Always pull the base image
  --jobs N                  Build up to N images in parallel (default: 1)
  --dry-run                 Print what would be built without building

Environment:
  PYTHON                    Python interpreter used for hack/matrix.py
                            (default: python3)

Examples:
  ${SCRIPT_NAME} --all --runtime podman --jobs 4
  ${SCRIPT_NAME} debian 13
EOF
    exit "${exit_code}"
}

parse_args() {
    local args
    local options="h"
    local longoptions="help,runtime:,pull,jobs:,all,dry-run"
    if ! args=$(getopt --options="${options}" --longoptions="${longoptions}" --name="${SCRIPT_NAME}" -- "${@}"); then
        usage 2
    fi

    eval set -- "${args}"
    declare -g -a REST_ARGS=()

    while true; do
        case "${1}" in
            -h | --help)
                usage 0
                ;;
            --runtime)
                runtime=${2}
                shift 2
                ;;
            --pull)
                pull=always
                shift
                ;;
            --jobs)
                jobs=${2}
                shift 2
                ;;
            --all)
                all=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                printf 'unknown option: %s\n' "${1}" >&2
                usage 2
                ;;
        esac
    done

    REST_ARGS=("${@}")
}

validate_args() {
    if ((${#REST_ARGS[@]} > 2)); then
        printf 'unexpected argument: %s\n' "${REST_ARGS[2]}" >&2
        usage 2
    fi

    distro=${REST_ARGS[0]:-}
    version=${REST_ARGS[1]:-}

    if [[ ${runtime} != docker && ${runtime} != podman ]]; then
        printf 'unsupported runtime: %s\n' "${runtime}" >&2
        exit 2
    fi

    if [[ ! ${jobs} =~ ^[1-9][0-9]*$ ]]; then
        printf 'invalid job count: %s\n' "${jobs}" >&2
        exit 2
    fi

    if [[ ${all} == false && (-z ${distro} || -z ${version}) ]]; then
        usage 2
    fi
}

check_dependencies() {
    if [[ ${dry_run} == false ]] && ! command -v "${runtime}" >/dev/null 2>&1; then
        printf 'container runtime not found: %s\n' "${runtime}" >&2
        exit 1
    fi

    if ! command -v "${PYTHON}" >/dev/null 2>&1; then
        printf 'python interpreter not found: %s\n' "${PYTHON}" >&2
        exit 1
    fi
}

build_one() {
    local entry=${1}
    local entry_distro entry_version image dockerfile context
    IFS=$'\t' read -r entry_distro entry_version image dockerfile context _ <<<"${entry}"
    printf '==> building %s %s (%s)\n' "${entry_distro}" "${entry_version}" "${image}"
    local -a args=()
    if [[ ${runtime} == docker ]]; then
        if [[ ${pull} == always ]]; then
            args+=(--pull)
        fi
    else
        args+=("--pull=${pull}")
    fi
    if [[ ${dry_run} == true ]]; then
        printf '    %s build %s --tag %s --file %s %s\n' \
            "${runtime}" "${args[*]}" "${image}" "${ROOT_DIR}/${dockerfile}" "${ROOT_DIR}/${context}"
        return 0
    fi
    "${runtime}" build "${args[@]}" --tag "${image}" --file "${ROOT_DIR}/${dockerfile}" "${ROOT_DIR}/${context}"
}

main() {
    parse_args "${@}"
    validate_args
    check_dependencies

    export -f build_one
    export runtime pull ROOT_DIR dry_run

    local entries
    entries=$("${PYTHON}" "${ROOT_DIR}/hack/matrix.py" --format tsv)
    if [[ ${all} == false ]]; then
        entries=$(awk -F'\t' -v d="${distro}" -v v="${version}" '$1 == d && $2 == v' <<<"${entries}")
    fi

    if [[ -z ${entries} ]]; then
        printf 'no image in matrix.yaml matches the request\n' >&2
        exit 1
    fi

    local count
    count=$(wc -l <<<"${entries}")
    printf 'building %s image(s) with %s\n' "${count}" "${runtime}"
    printf '%s\n' "${entries}" | xargs -d '\n' -P "${jobs}" -I '{}' bash -c 'build_one "$@"' _ '{}'
    printf 'built %s image(s)\n' "${count}"
}

main "${@}"
