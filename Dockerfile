# Standard single-context build (echo_pubsub is a hex dep now). Deploy with:
#
#   fly deploy
#
# Base image tags: verify these match your toolchain (this project builds on
# Elixir 1.19.5 / Erlang OTP 28). Adjust if the exact hexpm tag differs.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.2
ARG DEBIAN_VERSION=bookworm-20260824-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:bookworm-slim"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*_*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Deps first for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# App + assets. Compile first: Phoenix colocated JS/CSS is emitted by `mix
# compile`, and tailwind/esbuild need it before bundling.
COPY priv priv
COPY lib lib
COPY assets assets
RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/score_board ./
RUN chmod +x /app/bin/cluster_start.sh

USER nobody

CMD ["/app/bin/cluster_start.sh"]
