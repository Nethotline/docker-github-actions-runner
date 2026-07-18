#!/usr/bin/env bash
set -euo pipefail

function install_git() {
  ( apt-get install -y --no-install-recommends git \
   || apt-get install -t stable -y --no-install-recommends git )
}

function install_liblttng-ust() {
  if [[ $(apt-cache search -n liblttng-ust0 | awk '{print $1}') == "liblttng-ust0" ]]; then
    apt-get install -y --no-install-recommends liblttng-ust0
  fi

  if [[ $(apt-cache search -n liblttng-ust1 | awk '{print $1}') == "liblttng-ust1" ]]; then
    apt-get install -y --no-install-recommends liblttng-ust1
  fi
}

function install_aws-cli() {
  ( curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip" \
    && unzip -q awscliv2.zip -d /tmp/ \
    && /tmp/aws/install \
    && rm awscliv2.zip \
  ) \
    || pip3 install --no-cache-dir awscli
}

function install_git-lfs() {
  local DPKG_ARCH
  DPKG_ARCH="$(dpkg --print-architecture)"
  GIT_LFS_VERSION=$(curl -sL -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/git-lfs/git-lfs/releases/latest \
      | jq -r '.tag_name' | sed 's/^v//g')

  curl -s "https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/git-lfs-linux-${DPKG_ARCH}-v${GIT_LFS_VERSION}.tar.gz" -L -o /tmp/lfs.tar.gz
  tar -xzf /tmp/lfs.tar.gz -C /tmp
  "/tmp/git-lfs-${GIT_LFS_VERSION}/install.sh"
  rm -rf /tmp/lfs.tar.gz "/tmp/git-lfs-${GIT_LFS_VERSION}"
}

function install_docker-cli() {
  apt-get install -y docker-ce-cli --no-install-recommends --allow-unauthenticated
}

function install_docker() {
  apt-get install -y docker-ce docker-ce-cli docker-buildx-plugin containerd.io docker-compose-plugin --no-install-recommends --allow-unauthenticated

  echo -e '#!/bin/sh\ndocker compose --compatibility "$@"' > /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose

  sed -i 's/ulimit -Hn/# ulimit -Hn/g' /etc/init.d/docker
}

function install_container-tools() {
  ( apt-get install -y --no-install-recommends podman buildah skopeo || : )
}

function install_github-cli() {
  local DPKG_ARCH GH_CLI_VERSION GH_CLI_DOWNLOAD_URL

  DPKG_ARCH="$(dpkg --print-architecture)"

  GH_CLI_VERSION=$(curl -sL -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/cli/cli/releases/latest \
      | jq -r '.tag_name' | sed 's/^v//g')

  GH_CLI_DOWNLOAD_URL=$(curl -sL -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/cli/cli/releases/latest \
      | jq ".assets[] | select(.name == \"gh_${GH_CLI_VERSION}_linux_${DPKG_ARCH}.deb\")" \
      | jq -r '.browser_download_url')

  curl -sSLo /tmp/ghcli.deb "${GH_CLI_DOWNLOAD_URL}"
  apt-get -y install /tmp/ghcli.deb
  rm /tmp/ghcli.deb
}

function install_yq() {
  local DPKG_ARCH YQ_DOWNLOAD_URL

  DPKG_ARCH="$(dpkg --print-architecture)"

  YQ_DOWNLOAD_URL=$(curl -sL -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/mikefarah/yq/releases/latest \
      | jq ".assets[] | select(.name == \"yq_linux_${DPKG_ARCH}.tar.gz\")" \
      | jq -r '.browser_download_url')

  curl -s "${YQ_DOWNLOAD_URL}" -L -o /tmp/yq.tar.gz
  tar -xzf /tmp/yq.tar.gz -C /tmp
  mv "/tmp/yq_linux_${DPKG_ARCH}" /usr/local/bin/yq
}

function install_powershell() {
  local DPKG_ARCH PWSH_VERSION PWSH_DOWNLOAD_URL

  DPKG_ARCH="$(dpkg --print-architecture)"

  PWSH_VERSION=$(curl -sL -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
      | jq -r '.tag_name' \
      | sed 's/^v//g')

  PWSH_DOWNLOAD_URL=$(curl -sL -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/PowerShell/PowerShell/releases/latest \
      | jq -r ".assets[] | select(.name == \"powershell-${PWSH_VERSION}-linux-${DPKG_ARCH//amd64/x64}.tar.gz\") | .browser_download_url")

  curl -L -o /tmp/powershell.tar.gz "$PWSH_DOWNLOAD_URL"
  mkdir -p /opt/powershell
  tar zxf /tmp/powershell.tar.gz -C /opt/powershell
  chmod +x /opt/powershell/pwsh
  ln -s /opt/powershell/pwsh /usr/bin/pwsh
}

function install_temurin() {
  # Eclipse Temurin JDK 21 — required by the Android Gradle builds and by the
  # sdkmanager used to bake the SDK below. The Adoptium "latest GA" API URL
  # always resolves to the newest 21.x, so no version pin to bump here.
  local DPKG_ARCH ADOPT_ARCH
  DPKG_ARCH="$(dpkg --print-architecture)"
  case "$DPKG_ARCH" in
    amd64) ADOPT_ARCH="x64" ;;
    arm64) ADOPT_ARCH="aarch64" ;;
    *) echo "install_temurin: skipping unsupported arch ${DPKG_ARCH}"; return 0 ;;
  esac
  curl -fsSL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/${ADOPT_ARCH}/jdk/hotspot/normal/eclipse" -o /tmp/temurin.tar.gz
  mkdir -p /opt/java
  tar -xzf /tmp/temurin.tar.gz -C /opt/java --strip-components=1
  rm -f /tmp/temurin.tar.gz
  chmod -R a+rX /opt/java
}

function install_android-sdk() {
  # Android SDK matching the SeTaFo Capacitor release builds: platform-tools,
  # platforms;android-35, build-tools;35.0.0 (compileSdk/targetSdk 35, AGP 8.7.2).
  # x86_64 only — Google ships the SDK command-line tools for linux-x86_64; the
  # arm64 image variant skips it (the SeTaFo build pool is x86_64).
  local DPKG_ARCH
  DPKG_ARCH="$(dpkg --print-architecture)"
  if [[ "$DPKG_ARCH" != "amd64" ]]; then
    echo "install_android-sdk: skipping on ${DPKG_ARCH} (SDK is linux-x86_64 only)"
    return 0
  fi
  # cmdline-tools build number (the installer). Bump alongside major SDK upgrades.
  local CMDLINE_TOOLS_BUILD="11076708"
  local ANDROID_HOME="/opt/android-sdk"
  # sdkmanager is a Java program; point it at the JDK install_temurin just laid down.
  export JAVA_HOME="/opt/java"
  export PATH="${JAVA_HOME}/bin:${PATH}"
  mkdir -p "${ANDROID_HOME}/cmdline-tools"
  curl -fsSL "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip" -o /tmp/cmdline-tools.zip
  unzip -q /tmp/cmdline-tools.zip -d "${ANDROID_HOME}/cmdline-tools"
  mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
  rm -f /tmp/cmdline-tools.zip
  local SDKMANAGER="${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
  # Accept licenses. printf (not `yes |`) keeps this pipefail-safe — `yes` would
  # be SIGPIPE-killed when sdkmanager stops reading and fail the pipeline.
  printf 'y\n%.0s' {1..50} | "$SDKMANAGER" --sdk_root="${ANDROID_HOME}" --licenses > /dev/null
  "$SDKMANAGER" --sdk_root="${ANDROID_HOME}" \
    "platform-tools" "platforms;android-35" "build-tools;35.0.0" > /dev/null
  # World-readable: jobs run as the unprivileged `runner` user (created later in
  # install_base.sh) and only read the SDK at build time.
  chmod -R a+rX "${ANDROID_HOME}"
}

function install_playwright-deps() {
  # System libraries Chromium needs to launch, baked in so the
  # `[self-hosted, e2e]` runner can run `npx playwright install chromium`
  # (without `--with-deps`) and have the host deps already present — see
  # SeTaFo1 #1259 / #944. This mirrors what `playwright install-deps chromium`
  # lays down on Ubuntu 24.04. Source of truth for the set:
  # microsoft/playwright packages/playwright-core/src/server/registry/nativeDeps.ts
  # (the ubuntu24.04 `tools` fonts + `chromium` libs).
  #
  # xvfb and the legacy core-X bitmap font packages (xfonts-*) are intentionally
  # omitted: Playwright drives Chromium headless in CI, which renders through
  # fontconfig/FreeType and never consults the X core font path or needs an X
  # server. (Dropping xfonts-cyrillic also keeps the Debian matrix building — it
  # is Ubuntu-only.) WebKit deps are omitted too — the mobile specs are pinned to
  # Chromium (see #1259). libfontconfig1/libfreetype6 already come from the
  # skiasharp-native apt category.
  local packages=(
    # Chromium runtime libs whose package names are stable across releases.
    libcairo2 libdbus-1-3 libdrm2 libgbm1 libnspr4 libnss3 libpango-1.0-0
    libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3
    libxkbcommon0 libxrandr2
    # Fontconfig-registered fonts for correct text/emoji rendering in the
    # browser (all present on both Ubuntu and Debian).
    fonts-liberation fonts-noto-color-emoji fonts-unifont fonts-ipafont-gothic
    fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf
  )

  # Ubuntu 24.04's 64-bit time_t transition renamed these libraries with a `t64`
  # suffix; noble/trixie ship the new name, focal/jammy/bookworm the legacy one.
  # Probe the apt cache for each — the same approach install_liblttng-ust uses —
  # so this stays correct across every OS in the build matrix.
  local base pkg show
  for base in libasound2 libatk-bridge2.0-0 libatk1.0-0 libatspi2.0-0 libcups2 libglib2.0-0; do
    for pkg in "${base}t64" "${base}"; do
      # Capture apt-cache output first, then grep it — do NOT pipe apt-cache
      # straight into `grep -q`. grep -q closes the pipe on its first match and,
      # because tools.sh runs under `set -o pipefail`, the SIGPIPE that kills
      # apt-cache (these libs emit multiple records) would surface as the
      # pipeline's exit status and make the test spuriously fail. Same reason
      # install_liblttng-ust captures into a subshell before comparing.
      show="$(apt-cache show "${pkg}" 2>/dev/null || true)"
      if grep -q "^Package: ${pkg}\$" <<<"${show}"; then
        packages+=("${pkg}")
        break
      fi
    done
  done

  apt-get install -y --no-install-recommends "${packages[@]}"
}

function install_tools() {
  local function_name
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

  script_packages | while read -r package; do
    function_name="install_${package}"
    if declare -f "${function_name}" > /dev/null; then
      "${function_name}"
    else
      echo "No install script found for package: ${package}"
      exit 1
    fi
  done
}
