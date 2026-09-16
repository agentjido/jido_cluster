FROM hexpm/elixir:1.19.5-erlang-28.3.1-debian-bookworm-20260610-slim@sha256:88431cba2a104e27c22ff5e116d01f8befe246e0b655ead015fa8c3230dacf8a
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY jido_action /workspace/jido_action
COPY jido_signal /workspace/jido_signal
COPY jido /workspace/jido
COPY jido_cluster /workspace/jido_cluster
COPY docker_host /workspace/docker_host
ENV MIX_ENV=prod JIDO_SDK_ROOT=/workspace
WORKDIR /workspace/docker_host
RUN mix deps.get --only prod && mix compile --warnings-as-errors && mix release --overwrite
CMD ["_build/prod/rel/jido_cluster_docker_host/bin/jido_cluster_docker_host", "start"]
