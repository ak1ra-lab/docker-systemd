#!/usr/bin/env bash
# Rebuild the matrix images from the GitHub Actions build cache and load them
# into Podman.
#
# GitHub Actions only. The cache backend needs the Actions runtime token, which
# the runner exposes to actions but not to run steps, so this script must be
# invoked from a Node action (the CI workflow wraps it in actions/github-script).
# The build-smoke jobs write every layer to that cache with
# `cache-to: type=gha,mode=max`, so rebuilding here takes seconds per image
# instead of a cold Podman build.
#
# Images are loaded into rootful Podman (via sudo when not run as root)
# because that is how hack/molecule-test.sh runs the scenario in CI. Loads are
# serialized because Podman does not like concurrent writers to its storage.
set -o errexit -o nounset -o errtrace

SCRIPT_FILE="$(readlink -f "${0}")"
SCRIPT_NAME="$(basename "${SCRIPT_FILE}")"

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
PYTHON=${PYTHON:-python3}

arch=amd64
jobs=4
dry_run=false
work_dir=""

usage() {
    local exit_code="${1:-0}"
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Rebuild every image in matrix.yaml from the GitHub Actions build cache and
load it into Podman. Only usable inside GitHub Actions.

Options:
  -h, --help    Show this help
  --arch ARCH   Architecture to build and load (default: amd64)
  --jobs N      Build up to N images in parallel (default: 4)
  --dry-run     Print the build commands without running them

Environment:
  PYTHON        Python interpreter used for hack/matrix.py (default: python3)
EOF
    exit "${exit_code}"
}

cleanup() {
    local exit_code=$?
    trap - EXIT INT TERM
    if [[ -n ${work_dir} ]]; then
        rm -rf "${work_dir}"
    fi
    exit "${exit_code}"
}

parse_args() {
    local args
    local options="h"
    local longoptions="help,arch:,jobs:,dry-run"
    if ! args=$(getopt --options="${options}" --longoptions="${longoptions}" --name="${SCRIPT_NAME}" -- "${@}"); then
        usage 2
    fi

    eval set -- "${args}"

    while true; do
        case "${1}" in
            -h | --help)
                usage 0
                ;;
            --arch)
                arch=${2}
                shift 2
                ;;
            --jobs)
                jobs=${2}
                shift 2
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

    if (($# > 0)); then
        printf 'unexpected argument: %s\n' "${1}" >&2
        usage 2
    fi
}

validate_args() {
    if [[ -z ${arch} ]]; then
        printf 'empty architecture\n' >&2
        exit 2
    fi

    if [[ ! ${jobs} =~ ^[1-9][0-9]*$ ]]; then
        printf 'invalid job count: %s\n' "${jobs}" >&2
        exit 2
    fi
}

check_dependencies() {
    if [[ ${dry_run} == true ]]; then
        return 0
    fi

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
}

print_dry_run() {
    local entries=${1}
    local distro version image dockerfile context
    while IFS=$'\t' read -r distro version image dockerfile context _; do
        [[ -n ${distro} ]] || continue
        printf 'docker buildx build --file %s --tag %s --platform linux/%s --pull --cache-from type=gha,scope=%s-%s-%s --output type=docker,dest=%s/%s-%s.tar %s\n' \
            "${ROOT_DIR}/${dockerfile}" "${image}" "${arch}" \
            "${distro}" "${version}" "${arch}" "${work_dir}" "${distro}" "${version}" \
            "${ROOT_DIR}/${context}"
    done <<<"${entries}"
}

build_one() {
    local entry=${1}
    local entry_distro entry_version image dockerfile context
    IFS=$'\t' read -r entry_distro entry_version image dockerfile context _ <<<"${entry}"
    local archive="${work_dir}/${entry_distro}-${entry_version}.tar"
    printf '==> building %s %s\n' "${entry_distro}" "${entry_version}"
    docker buildx build \
        --file "${ROOT_DIR}/${dockerfile}" \
        --tag "${image}" \
        --platform "linux/${arch}" \
        --pull \
        --cache-from "type=gha,scope=${entry_distro}-${entry_version}-${arch}" \
        --output "type=docker,dest=${archive}" \
        "${ROOT_DIR}/${context}"
    printf '==> loading %s\n' "${image}"
    (
        flock 9
        if ((EUID == 0)); then
            podman load --input "${archive}"
        else
            sudo podman load --input "${archive}"
        fi
    ) 9>"${work_dir}/podman-load.lock"
    rm -f "${archive}"
}

main() {
    parse_args "${@}"
    validate_args
    check_dependencies

    work_dir=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    local entries
    entries=$("${PYTHON}" "${ROOT_DIR}/hack/matrix.py" --format tsv)
    if [[ -z ${entries} ]]; then
        printf 'no images found in matrix.yaml\n' >&2
        exit 1
    fi
    local count
    count=$(wc -l <<<"${entries}")

    if [[ ${dry_run} == true ]]; then
        print_dry_run "${entries}"
        return 0
    fi

    printf 'building %s image(s) from the GitHub Actions cache (arch=%s, jobs=%s)\n' \
        "${count}" "${arch}" "${jobs}"
    export -f build_one
    export ROOT_DIR work_dir arch
    printf '%s\n' "${entries}" | xargs -d '\n' -P "${jobs}" -I '{}' bash -c 'set -o errexit -o nounset; build_one "$@"' _ '{}'

    printf 'loaded %s image(s) into podman\n' "${count}"
}

main "${@}"
