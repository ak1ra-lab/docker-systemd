#!/usr/bin/env bash
# Run every linter used by CI against the repository.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
cd "$ROOT_DIR"

if [[ -d ${ROOT_DIR}/.venv/bin ]]; then
    PATH="${ROOT_DIR}/.venv/bin:${PATH}"
fi

PYTHON=${PYTHON:-python3}

printf '==> shellcheck\n'
shellcheck hack/*.sh

printf '==> shfmt\n'
shfmt -d hack

if command -v ruff >/dev/null 2>&1; then
    printf '==> ruff (check)\n'
    ruff check hack
    printf '==> ruff (format)\n'
    ruff format --check hack
else
    printf '==> ruff (skipped, not installed)\n'
fi

if command -v yamllint >/dev/null 2>&1; then
    printf '==> yamllint\n'
    yamllint .
else
    printf '==> yamllint (skipped, not installed)\n'
fi

if command -v ansible-lint >/dev/null 2>&1; then
    printf '==> ansible-lint\n'
    ansible-lint molecule/systemd
else
    printf '==> ansible-lint (skipped, not installed)\n'
fi

if command -v hadolint >/dev/null 2>&1; then
    printf '==> hadolint\n'
    hadolint images/*/*/Dockerfile
elif command -v docker >/dev/null 2>&1; then
    printf '==> hadolint (container image)\n'
    docker run --rm -v "${ROOT_DIR}:/src:ro" -w /src hadolint/hadolint:v2.15.1 \
        hadolint images/*/*/Dockerfile
else
    printf '==> hadolint (skipped, neither hadolint nor docker available)\n'
fi

printf '==> generated files are up to date\n'
"$PYTHON" hack/generate.py --check
