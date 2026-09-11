#!/usr/bin/env bash
# Run the Ansible-native Molecule scenario against the matrix images.
#
# The scenario uses the containers.podman connection plugin, so Podman is
# required. Run this as a normal user for rootless Podman, or as root for
# rootful Podman (which is what CI does for reliability).
set -o errexit -o nounset -o errtrace

SCRIPT_FILE="$(readlink -f "${0}")"
SCRIPT_NAME="$(basename "${SCRIPT_FILE}")"

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
cd "${ROOT_DIR}"

build=false

usage() {
    local exit_code="${1:-0}"
    cat <<EOF
Usage: ${SCRIPT_NAME} [--build] [-- molecule options]

Options:
  -h, --help  Show this help
  --build     Build every matrix image with Podman before testing

Environment:
  JOBS        Parallel builds when --build is used (default: 4)

Examples:
  ${SCRIPT_NAME} --build
  ${SCRIPT_NAME} -- -v
EOF
    exit "${exit_code}"
}

parse_args() {
    local args
    local options="h"
    local longoptions="help,build"
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
            --build)
                build=true
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

main() {
    parse_args "${@}"

    if ! command -v molecule >/dev/null 2>&1; then
        printf 'molecule is not installed; run "make venv" and activate .venv, or use "make molecule"\n' >&2
        exit 1
    fi

    if [[ ${build} == true ]]; then
        "${ROOT_DIR}/hack/build.sh" --all --runtime podman --jobs "${JOBS:-4}"
    fi

    exec molecule test -s systemd "${REST_ARGS[@]}"
}

main "${@}"
