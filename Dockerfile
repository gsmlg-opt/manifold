# syntax=docker/dockerfile:1

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=28.2
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

ARG RELEASE=manifold
ARG NODE_MAJOR=24

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
  && mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list \
  && apt-get update -y \
  && apt-get install -y --no-install-recommends nodejs \
  && mix local.hex --force \
  && mix local.rebar --force \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod
ENV RELEASE_NAME=${RELEASE}

# Build-only placeholders for prod config evaluation (builder stage only).
ENV SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
ENV MANIFOLD_CONNECTOR_ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=

COPY mix.exs mix.lock ./
COPY config config
COPY apps apps
COPY package.json package-lock.json ./

RUN mix deps.get --only prod \
  && mix deps.compile

RUN if [ "$RELEASE" = "manifold" ]; then \
      mix run --no-start -e 'Application.ensure_all_started(:ssl); Mix.Task.run("npm.ci")' \
      && mix assets.deploy; \
    fi

RUN mix release ${RELEASE} --overwrite

FROM ${RUNNER_IMAGE} AS runner

ARG RELEASE=manifold

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    libncurses6 \
    libstdc++6 \
    openssl \
    tini \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --create-home --shell /bin/bash --uid 1000 app

WORKDIR /app

ENV MIX_ENV=prod
ENV HOME=/app
ENV LANG=C.UTF-8
ENV RELEASE_NAME=${RELEASE}
ENV PHX_SERVER=true

COPY --from=builder --chown=app:app /app/_build/prod/rel/${RELEASE} ./

USER app

EXPOSE 4290 4291 4292

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["sh", "-c", "exec /app/bin/${RELEASE_NAME} start"]
