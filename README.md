# docker-systemd

systemd-enabled Linux distribution container images for **Ansible Molecule
managed nodes**.

These images are test targets. They run `systemd` as PID 1, ship Python 3, a
working package manager, D-Bus and a small set of tools that Ansible needs to
manage a Linux host. They are built for CI, Molecule and Ansible role
compatibility testing.

**They are not production images.** They are not hardened, they are not
minimal for production workloads, and they intentionally keep a normal
distribution userland so that roles behave the way they do on a real host.

## Why a plain distribution image does not work

A stock `debian:13` or `fedora:44` container does not run `systemd`. There is
no init as PID 1 and no `/sbin/init`, so any role that uses
`ansible.builtin.systemd_service`, `ansible.builtin.service` or
`ansible.builtin.service_facts` fails with:

```text
System has not been booted with systemd as init system (PID 1). Can't operate.
```

Installing `systemd` in a container is not enough either. systemd must be the
container's init process, the container needs a cgroup v2 environment it can
manage, and the image has to avoid baking a fixed `/etc/machine-id` into every
container. These images take care of the image side; the runtime side is
documented below.

## What this is not

| | This project | Ansible Execution Environment |
| --- | --- | --- |
| Purpose | managed node / test target | controller runtime |
| Contains Ansible | no | yes (`ansible-core`, collections) |
| Contains Python 3 | yes | yes |
| Runs `systemd` as PID 1 | yes | no |
| Runs `sshd` | no | no (usually) |
| Managed by | Molecule via container connection plugins | `ansible-navigator` / `ansible-playbook` |
| Used for | testing roles against a distribution | running playbooks |

The images deliberately do **not** install `ansible`, `ansible-core` or
`openssh-server`. Modern Molecule manages containers with the
`containers.podman.podman` or `community.docker.docker` connection plugins,
which execute commands inside the container directly. There is no SSH hop and
no controller software needed inside the managed node.

## Supported distributions

<!-- BEGIN GENERATED MATRIX -->
| Distribution | Version | Base image | Aliases | Upstream EOL | Image |
| --- | --- | --- | --- | --- | --- |
| Debian | 13 (trixie) | `docker.io/library/debian:13` | `latest` | 2030-06-30 | `ghcr.io/ak1ra-lab/docker-systemd/debian:13` |
| Debian | 12 (bookworm) | `docker.io/library/debian:12` | - | 2028-06-30 | `ghcr.io/ak1ra-lab/docker-systemd/debian:12` |
| Ubuntu | 26.04 (resolute) | `docker.io/library/ubuntu:26.04` | `latest`, `lts` | 2031-05-29 | `ghcr.io/ak1ra-lab/docker-systemd/ubuntu:26.04` |
| Ubuntu | 24.04 (noble) | `docker.io/library/ubuntu:24.04` | - | 2029-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/ubuntu:24.04` |
| Rocky Linux | 10 | `docker.io/rockylinux/rockylinux:10` | `latest` | 2035-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/rocky:10` |
| Rocky Linux | 9 | `docker.io/rockylinux/rockylinux:9` | - | 2032-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/rocky:9` |
| AlmaLinux | 10 | `docker.io/library/almalinux:10` | `latest` | 2035-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/almalinux:10` |
| AlmaLinux | 9 | `docker.io/library/almalinux:9` | - | 2032-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/almalinux:9` |
| Fedora Linux | 44 | `docker.io/library/fedora:44` | `latest` | 2027-06-02 | `ghcr.io/ak1ra-lab/docker-systemd/fedora:44` |
| Fedora Linux | 43 | `docker.io/library/fedora:43` | - | 2026-12-09 | `ghcr.io/ak1ra-lab/docker-systemd/fedora:43` |
| CentOS Stream | 10 | `quay.io/centos/centos:stream10` | `latest` | 2030-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/centos-stream:10` |
| CentOS Stream | 9 | `quay.io/centos/centos:stream9` | - | 2027-05-31 | `ghcr.io/ak1ra-lab/docker-systemd/centos-stream:9` |
<!-- END GENERATED MATRIX -->

`amd64` and `arm64` images are built for every entry. Both architectures are
runtime-tested in CI on native GitHub Actions runners (no QEMU). See
[Multi-architecture](#multi-architecture).

Upstream EOL dates come from [endoflife.date](https://endoflife.date/) and are
recorded in `matrix.yaml`. When a release goes EOL it is removed from the
matrix; EOL releases are not kept as legacy images in the default maintenance
path.

## Image naming and tags

Images are published to GitHub Container Registry:

```text
ghcr.io/ak1ra-lab/docker-systemd/<distro>:<version>
```

Examples:

```text
ghcr.io/ak1ra-lab/docker-systemd/debian:13
ghcr.io/ak1ra-lab/docker-systemd/ubuntu:24.04
ghcr.io/ak1ra-lab/docker-systemd/rocky:9
ghcr.io/ak1ra-lab/docker-systemd/centos-stream:10
```

Tag policy:

* **Version tags** (`debian:13`, `ubuntu:24.04`) are immutable *in meaning*:
  `debian:13` always means the Debian 13 test image. The content is rebuilt
  weekly from the current upstream `debian:13`, so security updates flow in
  without changing the tag's meaning.
* **Alias tags** are floating and auto-updated from `matrix.yaml`:
  * `<distro>:latest` points to the newest supported release of that distro.
  * `ubuntu:lts` points to the newest supported Ubuntu LTS.
* Git commit SHAs and build dates are not part of the tag scheme. If you need
  bit-for-bit reproducibility, pin the image by digest:

  ```text
  ghcr.io/ak1ra-lab/docker-systemd/debian:13@sha256:<digest>
  ```

## Requirements

* A Linux host with **cgroup v2** (`stat -fc %T /sys/fs/cgroup` prints
  `cgroup2fs`). systemd containers do not work on cgroup v1 hosts.
* Docker or Podman.
* For rootless Podman, the cgroup v2 hierarchy must be delegated to your user
  (the default on current desktop distributions with a systemd user session).
* Ansible, if you want to run the smoke tests or the Molecule scenario.

## Usage with Docker

On a cgroup v2 host, the least-privilege command that boots systemd was
verified with Docker Engine 29 on Debian 13:

```bash
docker run -d --name systemd-test \
  --cap-add SYS_ADMIN \
  --security-opt apparmor=unconfined \
  --cgroupns=host \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  ghcr.io/ak1ra-lab/docker-systemd/debian:13

docker exec systemd-test systemctl is-system-running
docker exec systemd-test systemctl status
```

Why each option is needed:

* `--cap-add SYS_ADMIN` — systemd needs to mount filesystems and set up
  namespacing for services (`PrivateTmp=`, `ProtectSystem=`, ...). The systemd
  documentation explicitly says not to drop `CAP_SYS_ADMIN` from containers.
* `--cgroupns=host` and a writable `/sys/fs/cgroup` — with a private cgroup
  namespace and a read-only cgroup mount, systemd exits immediately. This
  combination was tested; it is required on Docker Engine 29 with cgroup v2.
* `--security-opt apparmor=unconfined` — on hosts with AppArmor enabled, the
  default `docker-default` profile blocks what systemd needs. Omit this flag on
  hosts without AppArmor.

`--privileged` also works and is simpler, but grants far more access than
needed. Use it only if a specific role requires it.

Running Ansible directly against the container (no SSH):

```bash
ansible -i systemd-test, all -c community.docker.docker -m ansible.builtin.setup
```

## Usage with Podman

Podman needs no extra privileges. This follows the official
[Molecule systemd container guide](https://docs.ansible.com/projects/molecule/guides/systemd-container/):

```bash
podman run -d --name systemd-test --systemd=always \
  ghcr.io/ak1ra-lab/docker-systemd/debian:13

podman exec systemd-test systemctl is-system-running
podman exec systemd-test systemctl status
```

`--systemd=always` wires up the cgroup and tmpfs mounts systemd needs. Rootless
Podman works when the cgroup v2 hierarchy is delegated to your user.

Running Ansible directly against the container:

```bash
ansible -i systemd-test, all -c containers.podman.podman -m ansible.builtin.setup
```

## Using with Molecule (Ansible-native)

This repository contains a working
[Ansible-native Molecule](https://docs.ansible.com/projects/molecule/ansible-native/)
scenario in [`molecule/systemd/`](molecule/systemd/) that uses these images as
managed nodes. It is also what CI runs.

The scenario uses a standard Ansible inventory. Container images are inventory
variables, and the lifecycle is driven by ordinary playbooks:

```yaml
# molecule/systemd/inventory/hosts.yml (generated from matrix.yaml)
all:
  children:
    molecule:
      hosts:
        debian-13:
          container_image: ghcr.io/ak1ra-lab/docker-systemd/debian:13
        rocky-9:
          container_image: ghcr.io/ak1ra-lab/docker-systemd/rocky:9
```

```yaml
# molecule/systemd/inventory/group_vars/molecule.yml
ansible_connection: containers.podman.podman
container_command: /sbin/init
container_systemd: always
```

```yaml
# molecule/systemd/create.yml (excerpt)
- name: Create containers from the inventory
  containers.podman.podman_container:
    name: "{{ item }}"
    image: "{{ hostvars[item]['container_image'] }}"
    command: "{{ hostvars[item]['container_command'] }}"
    systemd: "{{ hostvars[item]['container_systemd'] }}"
    state: started
  loop: "{{ groups['molecule'] }}"
```

```yaml
# molecule/systemd/converge.yml (excerpt)
- name: Start and enable the integration test service
  ansible.builtin.systemd_service:
    name: molecule-demo.service
    state: started
    enabled: true
```

`converge.yml` installs a package with `ansible.builtin.package`, deploys a
small `molecule-demo.service` unit and starts it with
`ansible.builtin.systemd_service`. `verify.yml` uses `service_facts` and a
heartbeat file that the service keeps updating to prove it is actually
running, then stops and disables it. No Ansible and no SSH server are
installed inside the image.

To use a Docker connection instead, the same scenario works with
`community.docker.docker_container` and `community.docker.docker`. The
container needs the same options as the `docker run` example above:

```yaml
- name: Create containers from the inventory
  community.docker.docker_container:
    name: "{{ item }}"
    image: "{{ hostvars[item]['container_image'] }}"
    command: /sbin/init
    capabilities: [SYS_ADMIN]
    security_opts: ["apparmor=unconfined"]
    cgroupns_mode: host
    volumes:
      - /sys/fs/cgroup:/sys/fs/cgroup:rw
    state: started
  loop: "{{ groups['molecule'] }}"
```

and set `ansible_connection: community.docker.docker` in the inventory. On
hosts without AppArmor, drop the `apparmor=unconfined` entry from
`security_opts`.

## systemd and cgroup model

The images provide the image-side half of the
[systemd Container Interface](https://systemd.io/CONTAINER_INTERFACE/):

| Responsibility | Where |
| --- | --- |
| `systemd` as PID 1 via `CMD ["/sbin/init"]` | image |
| `STOPSIGNAL SIGRTMIN+3` for clean shutdown | image |
| Empty `/etc/machine-id` so each container generates its own | image |
| D-Bus system bus available (socket activated) | image |
| Python 3, package manager, `sudo`, `iproute`, `procps`, CA certificates | image |
| cgroup v2 hierarchy and namespace | runtime |
| `CAP_SYS_ADMIN` / AppArmor profile / cgroup mount | runtime |
| Podman `--systemd=always` (`systemd: always` in Molecule) | runtime |
| tmpfs for `/run` and `/run/lock` (Podman systemd mode provides these) | runtime |

Deliberate choices:

* **No unit files are deleted or masked.** Older Molecule images removed
  `systemd*udev*` and `getty.target` as a workaround for high CPU usage. With
  current systemd, `systemd-udevd` does not start when `/sys` is read-only,
  getty services are not spawned for VTs that do not exist in the container,
  and `systemd-modules-load` is skipped unless the container is given full
  capabilities. Deleting unit files breaks `systemctl` fidelity and is no
  longer necessary.
* **No `VOLUME ["/sys/fs/cgroup"]`.** cgroup mounting is a runtime
  responsibility; declaring anonymous volumes only creates surprises.
* **No `ENV container=...`.** Podman sets `container=podman` itself and systemd
  detects Docker through `/.dockerenv`, so `systemd-detect-virt -c` reports
  `docker` or `podman` correctly.
* **`degraded` is an acceptable boot state.** In containers some units are
  expected to fail or be skipped (for example module loading). Tests accept
  `running` or `degraded`, and never require `running` alone.

## Building locally

```bash
make venv                 # create .venv with PyYAML, Jinja2, Molecule, linters
make generate             # regenerate Dockerfiles from matrix.yaml
make build                # build every image with Podman, 4 in parallel
make build RUNTIME=docker # build with Docker instead
```

`hack/build.sh` can also build a single image:

```bash
hack/build.sh debian 13
hack/build.sh --all --runtime docker --jobs 4 --pull
```

The build context of every image is just its own directory; there are no
shared build artifacts.

Multi-architecture builds use Docker Buildx or `podman build --platform`; see
`.github/workflows/ci.yml` for the CI implementation.

## Smoke tests

A successful build does not prove the image works. Every image is started and
exercised:

```bash
make smoke                       # every image, Podman
hack/smoke-test.sh --all --runtime docker
hack/smoke-test.sh ghcr.io/ak1ra-lab/docker-systemd/debian:13
```

The smoke test verifies:

* systemd is PID 1 and reaches `running` or `degraded`;
* systemd detects that it runs in a container (`systemd-detect-virt -c`);
* `systemctl list-units`, `systemctl status` work;
* the system D-Bus is usable (`busctl list`);
* `python3` runs and `/etc/machine-id` is not empty;
* a package manager is present;
* a generated `molecule-test.service` can be started, restarted, stopped,
  enabled and disabled, and the process really exists while running;
* Ansible facts can be gathered with the runtime's connection plugin.

`ansible-core` and the `community.docker` / `containers.podman` collections
must be installed for the facts check.

## Molecule integration test

```bash
make molecule
# or, step by step:
hack/build.sh --all --runtime podman
molecule test -s systemd
```

CI runs the scenario as root with rootful Podman on GitHub-hosted runners.
Rootful Podman avoids rootless cgroup delegation differences on CI runners and
is the most predictable way to run systemd containers there. Locally, rootless
Podman is the recommended path and is what the examples use. Docker is covered
by the per-image smoke tests plus the documented `docker run` and
`community.docker` configuration.

## Adding a distribution or version

1. Edit `matrix.yaml`: add or update a distro version with its `base_image`,
   `eol` date and alias tags.
2. Run `make generate`. This updates the Dockerfiles, the Molecule inventory
   and the table in this README.
3. Run `make build` and `make smoke`.
4. Run `make molecule` if you want the full integration check.
5. Commit the changes, including generated files.

Adding a new distribution family (a new package manager or init layout) means
adding a template under `templates/` and a `families` entry; no CI changes are
needed because workflows read `matrix.yaml`.

Removing an EOL release is the same flow in reverse: delete it from
`matrix.yaml`, run `make generate`, and commit. CI fails if generated files
drift from `matrix.yaml`.

See [`docs/maintenance.md`](docs/maintenance.md) for the full maintenance
policy.

## Release and rebuild policy

* Every pull request runs lint, a build and smoke test for every image and
  architecture, and the Molecule integration test.
* Pushes to `main` run the same checks — lint, build-smoke and molecule — and
  then publish multi-architecture manifests to GHCR.
* A scheduled run every Monday at 03:17 UTC rebuilds everything from the
  current upstream base images. This is how security updates reach the images
  even when this repository does not change. Scheduled runs execute lint,
  build-smoke and molecule before publishing.
* `workflow_dispatch` allows manual rebuilds.

Version tags are updated in place by these rebuilds. Consumers who need an
immutable reference should pin by digest.

The workflows assume the default branch is named `main`; adjust the triggers
in `.github/workflows/ci.yml` if your default branch differs. The first
publish creates the GHCR packages; set their visibility to public in the
package settings if you want anonymous pulls.

## Security and reproducibility

Base images are referenced by tag (`debian:13`, `rocky:9`, ...) and **not**
pinned by digest. The rationale:

* These are CI test images. Automatically picking up upstream security fixes
  matters more than bit-for-bit reproducibility.
* A weekly scheduled rebuild re-resolves each base tag, so fixes flow in
  without human intervention.
* BuildKit resolves the base tag to a digest for cache invalidation, and the
  published image records its base via `org.opencontainers.image.base.name`
  plus the build revision label.
* Consumers who need reproducibility can pin the published image by digest;
  digests are visible in the registry.

If this project ever needs digest pinning, the change is local to
`matrix.yaml`: replace `base_image: debian:13` with
`base_image: debian:13@sha256:...` and add a dependency bot (Renovate
understands Docker digests). It is intentionally not enabled by default because
a bot that is not installed would silently freeze the images on old base
digests.

Downloaded package archives are removed at build time, but package-manager
metadata (`apt` lists, `dnf` repository metadata) is kept on purpose: roles
that install packages behave the same way they do on a real host, without
needing an explicit cache update first. The cost is roughly 20 MB per
Debian-family image and 90 MB per RPM-family image, which is an acceptable
trade for test fidelity.
No secrets or credentials are used or stored. GitHub Actions are pinned by
commit SHA.

## Support and EOL policy

* Only distributions that upstream still supports are in `matrix.yaml`.
* EOL dates are recorded per version and reviewed as part of routine
  maintenance; maintainers remove EOL releases in a dedicated change.
* There is no legacy path for EOL images in the default workflow. If EOL
  images are ever needed (for example to test a role on a frozen platform),
  they should be built from a separate, clearly named repository or branch
  rather than mixed into this matrix.

## Multi-architecture

`linux/amd64` and `linux/arm64` are built for every image, and both are
runtime-tested natively in CI:

* `ubuntu-24.04` (amd64) and `ubuntu-24.04-arm` (arm64) run the build and the
  full smoke test.
* Multi-architecture manifests are assembled and pushed by Buildx. The publish
  job runs on amd64 and uses QEMU only to cross-build the arm64 half.

No QEMU runtime testing is used, so the arm64 results reflect native execution.
Note that amd64 images based on RHEL 10 (`rocky:10`, `almalinux:10`,
`centos-stream:10`) require an x86-64-v3 capable CPU, which is an upstream
requirement of RHEL 10; this is not a property of this project.

## References / Prior Art

This project was designed from public documentation and existing projects. The
implementation is an independent engineering effort; nothing here is claimed
to be original research.

Official documentation:

* [Ansible Molecule: Systemd container guide](https://docs.ansible.com/projects/molecule/guides/systemd-container/)
* [Ansible Molecule: Using podman containers](https://docs.ansible.com/projects/molecule/examples/podman/)
* [Ansible Molecule: Ansible-native configuration](https://docs.ansible.com/projects/molecule/ansible-native/)
* [systemd: Container Interface](https://systemd.io/CONTAINER_INTERFACE/)
* [containers.podman.podman_container](https://docs.ansible.com/ansible/latest/collections/containers/podman/podman_container_module.html)
* [containers.podman.podman connection](https://docs.ansible.com/ansible/latest/collections/containers/podman/podman_connection.html)
* [community.docker.docker_container](https://docs.ansible.com/ansible/latest/collections/community/docker/docker_container_module.html)
* [Docker: resource constraints and cgroup drivers](https://docs.docker.com/engine/containers/resource_constraints/)

Prior art:

* [geerlingguy/docker-debian12-ansible](https://github.com/geerlingguy/docker-debian12-ansible)
  and the other `geerlingguy/docker-*-ansible` repositories (MIT). They are an
  important reference for systemd containers, but this project deliberately
  does not copy their architecture: no Ansible inside the image, no
  `/etc/ansible/hosts`, no `initctl_faker`, no deletion of systemd udev/getty
  unit files, no `VOLUME /sys/fs/cgroup`, and no privileged container as the
  default. Those were sensible workarounds for older Molecule and cgroup v1
  environments; they are not needed with current systemd, cgroup v2 and
  Ansible-native Molecule.
* [endoflife.date](https://endoflife.date/) for distribution lifecycle data.
* The Molecule documentation's systemd guide is the basis for the Podman
  runtime model and the `container_command` / `container_systemd` inventory
  variables used by the integration scenario.

## License

MIT. See [LICENSE](LICENSE).
