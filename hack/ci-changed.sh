#!/usr/bin/env bash
# Decide which CI stages the changed files require.
#
# Used by the `changes` job in .github/workflows/ci.yml. Pushes and pull
# requests run the expensive build, smoke test, Molecule and publish stages
# only when the files those stages depend on changed. Scheduled and manual
# runs always run everything.
#
# Environment:
#   EVENT_NAME     github.event_name
#   BASE_SHA       commit to diff from (github.event.pull_request.base.sha or
#                  github.event.before)
#   HEAD_SHA       commit to diff to (github.sha)
#   GITHUB_OUTPUT  GitHub Actions output file
#
# Outputs:
#   build    true when the build, smoke test and Molecule scenario are needed
#   publish  true when the published images may have changed
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
cd "$ROOT_DIR"

event=${EVENT_NAME:-}
base=${BASE_SHA:-}
head=${HEAD_SHA:-}

build=false
publish=false

if [[ $event != push && $event != pull_request ]]; then
    build=true
    publish=true
elif [[ -z $base || $base =~ ^0+$ ]]; then
    # A new branch or a force push: there is no usable base commit.
    build=true
    publish=true
elif ! changed=$(git diff --name-only "$base" "$head"); then
    printf 'cannot diff %s..%s; running everything\n' "$base" "$head" >&2
    build=true
    publish=true
else
    while IFS= read -r path; do
        case "$path" in
        matrix.yaml | templates/* | images/* | hack/generate.py | hack/build.sh | hack/matrix.py | .github/workflows/*)
            publish=true
            build=true
            ;;
        molecule/* | hack/smoke-test.sh | hack/molecule-test.sh | hack/ci-load-images.sh | hack/ci-changed.sh | requirements-dev.txt)
            build=true
            ;;
        esac
    done <<<"$changed"
fi

printf 'build=%s\n' "$build" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
printf 'publish=%s\n' "$publish" >>"${GITHUB_OUTPUT:?GITHUB_OUTPUT is not set}"
printf 'build=%s publish=%s\n' "$build" "$publish"
