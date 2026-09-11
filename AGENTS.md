# AGENTS.md

## What This Project Does

systemd-enabled Linux distribution container images used as Ansible Molecule
managed nodes. The images run systemd as PID 1 and exist for CI and Ansible
role compatibility testing, not production. `matrix.yaml` drives image
generation, builds and CI. See `README.md` for runtime usage, supported
distributions and policies.

## Environment & Tooling - CRITICAL

- Environment manager: the `Makefile` and the `.venv` it creates. Run
  `make venv` once; it installs the pinned tools from `requirements-dev.txt`.
  Use `make` targets instead of ad-hoc `pip install`.
- Test suite: there is no pytest or unittest suite. Run `make smoke` (runtime
  test of every built image) and `make molecule` (Molecule integration).
- Lint: `make lint` runs shellcheck, shfmt, ruff, yamllint, ansible-lint,
  hadolint and the generated-file drift check. It is check-only; apply
  formatting with `make format` (shfmt and ruff in write mode).
- `make build` uses Podman by default; pass `RUNTIME=docker` to use Docker.
- Smoke tests and Molecule need cgroup v2 and a working container runtime.
- MUST NOT edit generated files by hand:
  `images/<distro>/<version>/Dockerfile`,
  `molecule/systemd/inventory/hosts.yml`, or the README table between the
  `BEGIN/END GENERATED MATRIX` markers. Edit `matrix.yaml` or `templates/`
  and run `make generate`.
- MUST run `make generate` after changing `matrix.yaml` or `templates/`; CI
  fails when generated files drift.
- The Molecule scenario is Podman-only (`containers.podman.podman`
  connection). Do not switch it to Docker; Docker coverage lives in the smoke
  tests.

## Conventions

- `matrix.yaml` is the single source of truth for distributions, versions,
  base images, EOL dates and alias tags.
- Families (`debian`, `rhel`) group distros by package manager and share a
  Jinja2 template in `templates/`. Use `packages_add` / `packages_remove` per
  version in `matrix.yaml` instead of branching inside templates.
- Image names are `ghcr.io/ak1ra-lab/docker-systemd/<distro>:<version>`;
  Molecule host names drop dots (`ubuntu-2604`). Both are generated.
- Shell scripts live in `hack/`, are Bash with 4-space indent
  (`shfmt -i=4 -ci`) and must pass shellcheck. Python under `hack/` follows
  `ruff.toml` (88 columns, double quotes).
- Add new dev tools to `requirements-dev.txt`; CI installs only that file.

## Testing Guidelines

- Tests are shell and scenario based, not unit tests:
  - `hack/smoke-test.sh` boots an image and checks systemd as PID 1, D-Bus,
    Python, the package manager, service lifecycle and Ansible facts.
  - `molecule/systemd/` runs create, converge, idempotence, verify and
    destroy against every image in the generated inventory.
- Both use a real container runtime and real images; external I/O is not
  mocked.
- `verify.yml` asserts on `molecule-demo.service`; keep it in sync with
  `converge.yml` when the test service changes.
- New distros or versions are added in `matrix.yaml` only; never hardcode
  image lists in tests or scripts.

## Common Operations

```bash
make venv                    # create .venv and install requirements-dev.txt
make generate                # regenerate Dockerfiles, inventory, README table
make check                   # fail if generated files are stale
make lint                    # run all linters plus the drift check
make format                  # rewrite hack/ with shfmt and ruff
make build                   # build every image with Podman
RUNTIME=docker make build    # build every image with Docker
make smoke                   # runtime smoke test every image
make molecule                # build and run the Molecule scenario
hack/build.sh debian 13      # build a single image
hack/smoke-test.sh ghcr.io/ak1ra-lab/docker-systemd/debian:13  # smoke one image
```
