# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Docker image that runs GitHub's upstream [`actions/runner`](https://github.com/actions/runner) as a self-hosted runner. There is no application code — the repo is **Bash entrypoint scripts + a data-driven image build + goss assertions**. Published as `myoung34/github-runner` (and `github-runner-base`) on Docker Hub / GHCR across an OS × arch matrix.

## Two-layer image build

The build is intentionally split so the heavy toolchain layer is cached separately from the fast-changing runner layer:

- **`Dockerfile.base`** → `github-runner-base`. Runs `build/install_base.sh`, which installs all system tooling (docker, git, gh, pwsh, aws-cli, podman, node, python, etc.) and creates the `runner` user. This is the slow, rarely-changing layer.
- **`Dockerfile`** → `github-runner`. `FROM github-runner-base`, runs `install_actions.sh` to download the upstream runner tarball for `$TARGETPLATFORM`, then copies the runtime scripts (`entrypoint.sh`, `token.sh`, `app_token.sh`).

**The `FROM` lines are rewritten in CI**, not committed per-OS. CI does `sed -i 's/FROM.*/FROM <base>/'` to produce the matrix: Ubuntu `jammy`/`focal`/`noble` + Debian `bookworm`/`trixie`, each × `amd64`/`arm64`. When editing either Dockerfile, remember the `FROM` you see locally is a placeholder. `GH_RUNNER_VERSION` (the pinned upstream runner version) lives as an `ARG` in `Dockerfile`.

## Data-driven package installation (`build/`)

Packages are declared as data, not imperative steps. To add or change installed tooling, edit `build/config.json` — do **not** hand-edit install logic unless adding a new install method.

- **`config.json`** — declares uids/gids and every package, grouped by `category` and `source` (`apt` or `script`).
- **`config.sh`** — jq helpers that read `config.json` (`apt_packages`, `script_packages`, `user_id`, etc.).
- **`sources.sh`** — configures third-party apt repos (git-core PPA, Docker, kubic/container-tools) before install.
- **`tools.sh`** — one `install_<package>` Bash function per `script`-sourced package. `install_tools()` dispatches by reading `script_packages` and calling the matching function by name. **A `script` package in `config.json` with no `install_<name>` function in `tools.sh` fails the build.** Many of these resolve "latest" releases at build time via the GitHub API (gh, yq, powershell, git-lfs).
- **`install_base.sh`** — orchestrator: essentials → sources → apt packages → script packages → create `runner` user/groups → cleanup.

## Runtime scripts (image root)

- **`entrypoint.sh`** — the heart of the container. `dumb-init` PID 1. Responsibilities: derive runner name/scope, acquire a registration token, register via `config.sh`, trap signals for **auto-deregistration**, optional runner reusage, optional docker-in-docker start, then exec the runner as `root` or via `gosu runner`. Behavior is driven entirely by env vars (full table in `README.md`). Two important, non-obvious details:
  - Secrets (`ACCESS_TOKEN`, `RUNNER_TOKEN`, `APP_ID`, `APP_PRIVATE_KEY`) are `export -n`'d early so they don't leak into the workflow environment; `UNSET_CONFIG_VARS=true` unsets the rest.
  - When running as non-root, it deliberately does **not** recursively `chown` `bin/`+`externals/` (~380MB) — that would trigger per-file overlay copy-up and dominate startup under parallel runners. See the comment around the `find ... -maxdepth 1` call before changing chown logic.
- **`token.sh`** — exchanges a PAT (`ACCESS_TOKEN`) for a short-lived runner registration token via the GitHub API, branching on `RUNNER_SCOPE` (repo/org/enterprise).
- **`app_token.sh`** — GitHub App auth path: builds an RS256 JWT inline (openssl + base64url), finds the installation matching `APP_LOGIN`, returns an installation access token.

`token.sh` and `app_token.sh` share identical `normalize_host` / `normalize_api_path` helpers and the `GITHUB_HOST` / `GITHUB_API_HOST` / `GITHUB_API_PATH` resolution logic — keep them in sync when changing GitHub Enterprise / API-host handling.

## Tests (goss)

Tests are [goss](https://github.com/goss-org/goss/) assertions run via `dgoss` against a built image. Each scenario is a separate file; PRs are expected to add/extend assertions. Most run with `DEBUG_ONLY=true` so `entrypoint.sh` prints its config and execs the CMD without real registration.

- `goss_base.yaml` — packages/files/users present in the **base** image. Uses goss templating on `.Vars.oscodename` (e.g. focal lacks upstream podman/skopeo/buildah).
- `goss_full.yaml` — `entrypoint.sh` output with all env vars set; also unit-tests `token.sh` with a stubbed `curl`.
- `goss_full_defaults.yaml` — `entrypoint.sh` output with defaults only.
- `goss_reusage_fail.yaml` — asserts the guard that reusage requires `DISABLE_AUTOMATIC_DEREGISTRATION=true` (expects exit 1).
- `goss_trap_exit.yaml` — asserts the EXIT trap deregisters on process crash (`DEBUG_ONLY=false`, long timeout for arm64-under-qemu).

goss needs `GOSS_VARS` (os/oscodename/arch) interpolated; CI generates this file per matrix entry. To run a single scenario locally (see `README.md` for the full base+final build first):

```bash
printf 'os: ubuntu\noscodename: focal\narch: x86_64\n' > goss_vars.yaml
GOSS_VARS=goss_vars.yaml GOSS_FILE=goss_base.yaml GOSS_SLEEP=1 \
  dgoss run --entrypoint /usr/bin/sleep -e RUNNER_NAME=test -e DEBUG_ONLY=true <image> 10
```

## Lint

Shell is the primary language; lint is enforced in CI (`.github/workflows/test.yml` → `Lint` job) and not optional for a merge.

```bash
shellcheck *.sh build/*.sh      # pinned 0.11.0 (.tool-versions)
pre-commit run --all-files      # yaml/eol/whitespace/merge-conflict/private-key
```

`actionlint` runs on workflows via Sider (`sider.yml`).

## CI workflows (`.github/workflows/`)

- `test.yml` — PR gate: shellcheck + pre-commit, then build the combined Dockerfile and run the full goss suite across the OS/arch matrix.
- `deploy.yml` — builds and pushes the matrix images to Docker Hub + GHCR (nightly / on master merge).
- `base.yml` — builds and pushes the `github-runner-base` images.
- `release.yml` — versioned tags built on upstream `actions/runner` tags.

The CI build/test steps are the source of truth for the exact `dgoss` invocations and env-var combinations each scenario expects.
