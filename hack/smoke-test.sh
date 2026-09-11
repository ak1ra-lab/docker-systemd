#!/usr/bin/env bash
# Runtime smoke test for the systemd container images.
#
# Verifies that systemd is really PID 1 and usable: boot state, service
# lifecycle, Python, D-Bus and Ansible facts gathering. This is not a build
# test; a successful build means nothing if systemd does not come up.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
PYTHON=${PYTHON:-python3}

usage() {
    cat <<'EOF'
Usage: hack/smoke-test.sh [options] (--all | <image>)

Options:
  --runtime docker|podman   Container runtime to use (default: podman)
  --all                     Test every image in matrix.yaml
  --keep                    Keep the container when the test fails
  -h, --help                Show this help

The Docker path uses the least privileges that still boot systemd on a
cgroup v2 host: CAP_SYS_ADMIN, host cgroup namespace, a writable cgroup
mount and, on AppArmor hosts, an unconfined AppArmor profile. The Podman
path uses --systemd=always and needs no extra privileges.

Ansible (ansible-core) and the community.docker / containers.podman
collections must be installed for the facts check.
EOF
}

runtime=podman
keep=false
all=false
image=""

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
    --all)
        all=true
        shift
        ;;
    --keep)
        keep=true
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
        image=$1
        shift
        ;;
    esac
done

if [[ $runtime != docker && $runtime != podman ]]; then
    printf 'unsupported runtime: %s\n' "$runtime" >&2
    exit 2
fi

if [[ $all == false && -z $image ]]; then
    usage >&2
    exit 2
fi

if ! command -v "$runtime" >/dev/null 2>&1; then
    printf 'container runtime not found: %s\n' "$runtime" >&2
    exit 1
fi

if [[ $(stat -fc %T /sys/fs/cgroup) != cgroup2fs ]]; then
    printf 'cgroup v2 is required to run systemd in a container\n' >&2
    exit 2
fi

current_container=""

cleanup() {
    local exit_code=$?
    if [[ -n $current_container && $keep == false ]]; then
        "$runtime" rm -f "$current_container" >/dev/null 2>&1 || true
    fi
    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_args=()
connection=""
if [[ $runtime == docker ]]; then
    run_args=(--cap-add SYS_ADMIN --cgroupns=host --volume /sys/fs/cgroup:/sys/fs/cgroup:rw)
    if [[ -r /sys/module/apparmor/parameters/enabled ]] &&
        grep -q '^Y' /sys/module/apparmor/parameters/enabled; then
        run_args+=(--security-opt apparmor=unconfined)
    fi
    connection="community.docker.docker"
else
    run_args=(--systemd=always)
    connection="containers.podman.podman"
fi

check_ansible() {
    if ! command -v ansible >/dev/null 2>&1; then
        printf '  FAIL ansible is not installed (needed for the facts check)\n'
        return 1
    fi
    if ! ansible-doc -t connection "$connection" >/dev/null 2>&1; then
        printf '  FAIL Ansible collection for %s is not installed\n' "$connection"
        return 1
    fi
    return 0
}

run_smoke() {
    local target=$1
    local name="systemd-smoke-$$"
    local failures=0
    local state=""
    local output=""

    printf '\n== smoke test: %s (%s)\n' "$target" "$runtime"
    "$runtime" rm -f "$name" >/dev/null 2>&1 || true
    current_container="$name"

    if ! "$runtime" run -d --name "$name" "${run_args[@]}" "$target" >/dev/null; then
        printf '  FAIL could not start the container\n'
        return 1
    fi

    for _ in $(seq 1 60); do
        state=$("$runtime" exec "$name" systemctl is-system-running 2>/dev/null || true)
        case "$state" in
        running | degraded) break ;;
        esac
        if [[ $("$runtime" inspect -f '{{.State.Running}}' "$name" 2>/dev/null) != "true" ]]; then
            state="exited"
            break
        fi
        sleep 1
    done
    if [[ $state == running || $state == degraded ]]; then
        printf '  ok   systemd state: %s\n' "$state"
    else
        printf '  FAIL systemd did not reach running/degraded (state=%s)\n' "$state"
        failures=$((failures + 1))
    fi

    output=$("$runtime" exec "$name" cat /proc/1/comm 2>/dev/null || true)
    if [[ $output == systemd ]]; then
        printf '  ok   PID 1 is systemd\n'
    else
        printf '  FAIL PID 1 is %s\n' "$output"
        failures=$((failures + 1))
    fi

    output=$("$runtime" exec "$name" systemd-detect-virt -c 2>/dev/null || true)
    if [[ -n $output && $output != none ]]; then
        printf '  ok   container detection: %s\n' "$output"
    else
        printf '  FAIL systemd did not detect a container: %s\n' "$output"
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" systemctl list-units --no-pager >/dev/null 2>&1; then
        printf '  ok   systemctl list-units works\n'
    else
        printf '  FAIL systemctl list-units failed\n'
        failures=$((failures + 1))
    fi

    output=$("$runtime" exec "$name" python3 --version 2>&1 || true)
    if [[ $output == Python* ]]; then
        printf '  ok   %s\n' "$output"
    else
        printf '  FAIL python3 not executable: %s\n' "$output"
        failures=$((failures + 1))
    fi

    output=$("$runtime" exec "$name" cat /etc/machine-id 2>/dev/null || true)
    if [[ -n $output ]]; then
        printf '  ok   machine-id: %s\n' "$output"
    else
        printf '  FAIL machine-id is empty\n'
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" busctl --no-pager list >/dev/null 2>&1; then
        printf '  ok   system D-Bus is usable\n'
    else
        printf '  FAIL system D-Bus is not usable\n'
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" sh -c 'command -v dnf || command -v apt-get' >/dev/null 2>&1; then
        printf '  ok   package manager is present\n'
    else
        printf '  FAIL no supported package manager found\n'
        failures=$((failures + 1))
    fi

    printf '  -- service lifecycle\n'
    cat <<'EOF' | "$runtime" exec -i "$name" tee /etc/systemd/system/molecule-test.service >/dev/null
[Unit]
Description=Molecule smoke test service

[Service]
Type=simple
ExecStart=/bin/sleep infinity

[Install]
WantedBy=multi-user.target
EOF
    if "$runtime" exec "$name" systemctl daemon-reload &&
        "$runtime" exec "$name" systemctl start molecule-test.service; then
        printf '  ok   service started\n'
    else
        printf '  FAIL service failed to start\n'
        failures=$((failures + 1))
    fi

    output=$("$runtime" exec "$name" systemctl is-active molecule-test.service 2>/dev/null || true)
    if [[ $output == active ]]; then
        printf '  ok   service is active\n'
    else
        printf '  FAIL service is not active (%s)\n' "$output"
        failures=$((failures + 1))
    fi

    local main_pid
    main_pid=$("$runtime" exec "$name" systemctl show -p MainPID --value molecule-test.service 2>/dev/null || true)
    if [[ $main_pid != 0 && -n $main_pid ]] && "$runtime" exec "$name" kill -0 "$main_pid" 2>/dev/null; then
        printf '  ok   service process %s is alive\n' "$main_pid"
    else
        printf '  FAIL service process is not alive (MainPID=%s)\n' "$main_pid"
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" systemctl status molecule-test.service >/dev/null 2>&1; then
        printf '  ok   systemctl status works\n'
    else
        printf '  FAIL systemctl status failed\n'
        failures=$((failures + 1))
    fi

    local new_pid
    if "$runtime" exec "$name" systemctl restart molecule-test.service >/dev/null 2>&1; then
        new_pid=$("$runtime" exec "$name" systemctl show -p MainPID --value molecule-test.service 2>/dev/null || true)
        if [[ $new_pid != 0 && $new_pid != "$main_pid" ]]; then
            printf '  ok   restart replaced the process (%s -> %s)\n' "$main_pid" "$new_pid"
        else
            printf '  FAIL restart did not replace the process\n'
            failures=$((failures + 1))
        fi
    else
        printf '  FAIL restart failed\n'
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" systemctl stop molecule-test.service >/dev/null 2>&1; then
        output=$("$runtime" exec "$name" systemctl is-active molecule-test.service 2>/dev/null || true)
        if [[ $output == inactive ]] && ! "$runtime" exec "$name" kill -0 "$new_pid" 2>/dev/null; then
            printf '  ok   service stopped and the process is gone\n'
        else
            printf '  FAIL service did not stop cleanly (state=%s)\n' "$output"
            failures=$((failures + 1))
        fi
    else
        printf '  FAIL stop failed\n'
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" systemctl enable molecule-test.service >/dev/null 2>&1 &&
        [[ $("$runtime" exec "$name" systemctl is-enabled molecule-test.service 2>/dev/null) == enabled ]]; then
        printf '  ok   service enabled\n'
    else
        printf '  FAIL service could not be enabled\n'
        failures=$((failures + 1))
    fi

    if "$runtime" exec "$name" systemctl disable molecule-test.service >/dev/null 2>&1 &&
        [[ $("$runtime" exec "$name" systemctl is-enabled molecule-test.service 2>/dev/null || true) == disabled ]]; then
        printf '  ok   service disabled\n'
    else
        printf '  FAIL service could not be disabled\n'
        failures=$((failures + 1))
    fi

    printf '  -- ansible facts\n'
    if check_ansible; then
        output=$(ansible -i "${name}," all -c "$connection" -m ansible.builtin.setup 2>&1)
        if grep -q '"ansible_system"' <<<"$output"; then
            printf '  ok   %s\n' "$(grep -o '"ansible_distribution": "[^"]*"' <<<"$output" | head -1)"
        else
            printf '  FAIL Ansible facts gathering failed\n'
            tail -n 20 <<<"$output"
            failures=$((failures + 1))
        fi
    else
        failures=$((failures + 1))
    fi

    if ((failures > 0)); then
        printf '  -- container log (last 20 lines)\n'
        "$runtime" logs "$name" 2>&1 | tail -n 20
        if [[ $keep == true ]]; then
            printf 'kept container %s for debugging\n' "$name"
        else
            "$runtime" rm -f "$name" >/dev/null 2>&1 || true
            current_container=""
        fi
        printf 'SMOKE TEST FAILED: %s (%s), %d failure(s)\n' "$target" "$runtime" "$failures"
        return 1
    fi

    "$runtime" rm -f "$name" >/dev/null 2>&1 || true
    current_container=""
    printf 'SMOKE TEST PASSED: %s (%s)\n' "$target" "$runtime"
    return 0
}

if [[ $all == true ]]; then
    if ! entries=$("$PYTHON" "${ROOT_DIR}/hack/matrix.py" --format tsv); then
        printf 'failed to read the image matrix\n' >&2
        exit 1
    fi
    failures=0
    while IFS=$'\t' read -r _ _ target _ _ _; do
        run_smoke "$target" || failures=$((failures + 1))
    done <<<"$entries"
    if ((failures > 0)); then
        printf '\n%d image(s) failed the smoke test\n' "$failures"
        exit 1
    fi
    printf '\nall images passed the smoke test\n'
else
    run_smoke "$image"
fi
