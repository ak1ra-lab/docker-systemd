PYTHON ?= python3
VENV ?= .venv
RUNTIME ?= podman
JOBS ?= 4
PYTHON_BIN := $(VENV)/bin/python

.PHONY: help venv generate check lint build smoke molecule clean

help:
	@printf '%s\n' \
		'venv      create .venv and install requirements-dev.txt' \
		'generate  regenerate Dockerfiles, inventory and README table' \
		'check     verify generated files are up to date' \
		'lint      run shellcheck, shfmt, ruff, yamllint, ansible-lint, hadolint' \
		'build     build every image (RUNTIME=podman, JOBS=4)' \
		'smoke     run the runtime smoke test for every image' \
		'molecule  run the Ansible-native Molecule scenario' \
		'clean     remove .venv (the container build cache is left alone)'

$(PYTHON_BIN): requirements-dev.txt
	$(PYTHON) -m venv "$(VENV)"
	"$(VENV)/bin/pip" install --upgrade pip
	"$(VENV)/bin/pip" install -r requirements-dev.txt

venv: $(PYTHON_BIN)

generate: $(PYTHON_BIN)
	"$(PYTHON_BIN)" hack/generate.py

check: $(PYTHON_BIN)
	"$(PYTHON_BIN)" hack/generate.py --check

lint: $(PYTHON_BIN)
	PATH="$(CURDIR)/$(VENV)/bin:$$PATH" PYTHON="$(PYTHON_BIN)" hack/lint.sh

build: $(PYTHON_BIN)
	PYTHON="$(PYTHON_BIN)" hack/build.sh --all --runtime "$(RUNTIME)" --jobs "$(JOBS)"

smoke: $(PYTHON_BIN)
	PYTHON="$(PYTHON_BIN)" hack/smoke-test.sh --all --runtime "$(RUNTIME)"

molecule: $(PYTHON_BIN)
	PATH="$(CURDIR)/$(VENV)/bin:$$PATH" JOBS="$(JOBS)" hack/molecule-test.sh --build

clean:
	rm -rf "$(VENV)"
