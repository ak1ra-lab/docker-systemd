# Maintenance guide

This document describes how the image matrix is maintained after the initial
implementation. The short version:

* `matrix.yaml` is the single source of truth.
* Generated files are committed and checked in CI.
* Adding or removing a distribution is a data change, not a code change.
* Weekly rebuilds pick up upstream security updates.

## Source of truth and generated files

`matrix.yaml` defines the project metadata, registry namespace, image families
and every distro/version. The following files are generated from it by
`python3 hack/generate.py` (or `make generate`):

| Generated file | Purpose |
| --- | --- |
| `images/<distro>/<version>/Dockerfile` | the image build definition |
| `molecule/systemd/inventory/hosts.yml` | Molecule inventory hosts and images |
| `README.md` (between the `BEGIN/END GENERATED MATRIX` markers) | supported distribution table |

CI runs `hack/generate.py --check` and fails when a generated file is stale or
when a Dockerfile exists that is not in the matrix. Never edit generated files
by hand; edit `matrix.yaml` or `templates/` and regenerate.

## Adding a distribution or version

1. Add the version to `matrix.yaml` under the distro's `versions` list:

   ```yaml
   - version: "14"
     codename: forky
     base_image: docker.io/library/debian:14
     released: "2027-08-01"
     eol: "2031-06-30"
     aliases: [latest]
   ```

   Fields:
   * `version` (required): the tag suffix, e.g. `13` or `24.04`.
   * `base_image` (required): fully qualified upstream reference. Use the
     distribution's own official image, never a third-party rebuild.
   * `eol` (required): upstream end of life date from
     <https://endoflife.date/>.
   * `codename` (optional): used in the image title label and the README
     table.
   * `released` (optional): documentation only.
   * `aliases` (optional): floating tags that should point at this version,
     for example `latest` or `lts`. Only one version per distro should carry
     `latest`.
   * `packages_add` / `packages_remove` (optional): per-version package
     overrides on top of the family package list.

2. Run `make generate` and review the diff. If the new version is the newest
   supported release and should be the floating alias, move `latest` from the
   previous version.
3. Run `make build`, `make smoke` and `make molecule`.
4. Commit `matrix.yaml` together with the generated files.

No workflow changes are needed: CI reads the matrix from `matrix.yaml`.

## Adding a new distribution family

A family groups distributions that share a package manager and init layout.
To add one:

1. Add a template under `templates/`, for example
   `templates/Dockerfile.alpine.j2`. Use the existing templates as a model.
   The generator provides the placeholders `base_image`, `distro`, `version`,
   `codename`, `title`, `project`, `packages_block`, `post_install_block`,
   `init_path` and `stop_signal`.
2. Add a `families` entry in `matrix.yaml` with the template name, the base
   package list and any `enable_units` that must be enabled at build time.
3. Add the distro under `distros` and point it at the family.
4. Regenerate, build, smoke test and commit.

## Removing an EOL release

1. Delete the version from `matrix.yaml`.
2. Run `make generate`. The Dockerfile, inventory entry and README row
   disappear.
3. Commit. CI's drift check fails if any generated file is left behind.

EOL images are not preserved in this repository. If an EOL platform must be
tested, use a separate repository or branch with an explicit legacy name; do
not weaken the default matrix.

## End-of-life review

The `eol` dates in `matrix.yaml` are reviewed as part of routine maintenance.
A release should be removed when upstream support ends. Fedora has the
shortest window (about 13 months), so its entries are the ones that change
most often. When a distribution release reaches EOL:

1. Remove it from `matrix.yaml` and regenerate.
2. Move the `latest` alias to the newest supported release if needed.
3. Announce the removal in the release notes for the next rebuild.

## Local development workflow

```bash
make venv        # create .venv with PyYAML, Jinja2, Molecule and linters
make generate    # regenerate files from matrix.yaml
make lint        # shellcheck, shfmt, ruff, yamllint, ansible-lint, hadolint, drift check
make build       # build every image with Podman
make smoke       # run the runtime smoke test for every image
make molecule    # build and run the Molecule integration scenario
```

`RUNTIME=docker make build` builds with Docker instead of Podman.

On hosts without AppArmor the Docker smoke test automatically omits the
`--security-opt apparmor=unconfined` flag. On hosts with cgroup v1 the smoke
test exits immediately with a clear message; systemd containers require
cgroup v2.

## CI and release policy

| Event | What runs |
| --- | --- |
| Pull request | lint, build + smoke test (amd64 and arm64), Molecule integration |
| Push to `main` | the same checks, then multi-architecture publish to GHCR |
| Weekly schedule (Monday 03:17 UTC) | full rebuild, full test suite, publish |
| `workflow_dispatch` | manual rebuild with the same guarantees |

The publish job only runs after the lint, matrix, build-smoke and molecule
jobs succeed. Every scheduled rebuild re-runs the smoke tests before anything
is pushed.

## Tag policy

* `<distro>:<version>` tags are updated in place by rebuilds. Their meaning
  (`debian:13` means Debian 13) never changes.
* `latest` and `lts` aliases are derived from `matrix.yaml`; moving them is a
  deliberate commit.
* There are no date, commit or pipeline-id tags. Pin by image digest when an
  immutable reference is required.

## Base image digest policy

Base images are referenced by tag, not by digest. Weekly rebuilds re-resolve
the tags and pick up security updates automatically. If reproducible builds
become a hard requirement, change `base_image` entries in `matrix.yaml` to
`image:tag@sha256:...` and enable a digest-aware dependency bot; the rest of
the pipeline does not change. See the README section "Security and
reproducibility" for the full rationale.

## Tooling versions

`requirements-dev.txt` pins the Python tools used by lint and Molecule.
Dependabot (`.github/dependabot.yml`) keeps those pins and the pinned GitHub
Actions SHAs up to date. The Docker ecosystem is intentionally excluded from
Dependabot so that base images keep floating to the newest tag content between
weekly rebuilds.

## Troubleshooting

* **`System has not been booted with systemd as init system (PID 1)`** — the
  container was started without systemd as PID 1. With Docker, use the flags
  from the README. With Podman, pass `--systemd=always` or
  `container_systemd: always` in Molecule.
* **Docker exits with code 255 and no logs** — a capability or AppArmor
  problem. Check that `--cap-add SYS_ADMIN`, `--cgroupns=host`, the writable
  `/sys/fs/cgroup` mount and (on AppArmor hosts)
  `--security-opt apparmor=unconfined` are present.
* **`systemctl is-system-running` reports `degraded`** — normal for
  containers. Some units cannot work without a full init environment. Tests
  accept `running` and `degraded`.
* **RHEL 10 based images fail with `CPU does not support x86-64-v3`** — an
  upstream requirement of RHEL 10 on amd64, not an image bug. Use a
  v3-capable CPU or the arm64 image.
* **Rootless Podman fails to start systemd** — make sure cgroup v2 is in use
  and delegated to your user session.
