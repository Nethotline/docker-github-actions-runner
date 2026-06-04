# hadolint ignore=DL3007
# Built locally by .github/workflows/build.yml (docker build -f Dockerfile.base -t github-runner-base:latest)
FROM github-runner-base:latest
LABEL maintainer="kontakt@nethotline.io"

ENV AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache
RUN mkdir -p /opt/hostedtoolcache

# Redirect package caches onto the persistent /runner volume so `dotnet
# restore` / `npm ci` / Nx hit a warm local cache across runs (and survive
# container recreation). The tools create these dirs on first use. Adjust
# the /runner prefix if your runner mounts the persistent volume elsewhere.
ENV NUGET_PACKAGES=/runner/_cache/nuget \
    npm_config_cache=/runner/_cache/npm \
    NX_CACHE_DIRECTORY=/runner/_cache/nx \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1

ARG GH_RUNNER_VERSION="2.334.0"

ARG TARGETPLATFORM

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

WORKDIR /actions-runner
COPY install_actions.sh /actions-runner

RUN chmod +x /actions-runner/install_actions.sh \
  && /actions-runner/install_actions.sh ${GH_RUNNER_VERSION} ${TARGETPLATFORM} \
  && rm /actions-runner/install_actions.sh \
  && chown -R runner /_work /actions-runner /opt/hostedtoolcache

COPY token.sh entrypoint.sh app_token.sh /
RUN chmod +x /token.sh /entrypoint.sh /app_token.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["./bin/Runner.Listener", "run", "--startuptype", "service"]
