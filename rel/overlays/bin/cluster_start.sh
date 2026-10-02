#!/bin/sh
# Boots one isolated 3-node cluster inside a single fly machine.
#
# board2 and board3 run headless (no HTTP); board1 runs the Phoenix server in
# the foreground as the container's main process. All three discover each other
# through the machine-local epmd (Cluster.Strategy.LocalEpmd) and bind Erlang
# distribution to loopback, so nodes on other machines can never cluster in.
set -eu

RELEASE="${RELEASE_NAME:-score_board}"
BIN="/app/bin/${RELEASE}"

# Same cookie for all three; harmless to share across machines because
# distribution is loopback-only and discovery is machine-local.
export RELEASE_DISTRIBUTION=name
export RELEASE_COOKIE="${RELEASE_COOKIE:-score-board-demo-cookie}"

# Keep epmd and the distribution listener on loopback → hard network isolation.
export ERL_EPMD_ADDRESS=127.0.0.1
export ERL_AFLAGS="${ERL_AFLAGS:-} -kernel inet_dist_use_interface {127,0,0,1}"

start_headless() {
  n="$1"
  mkdir -p "/tmp/board${n}"
  env RELEASE_NODE="board${n}@127.0.0.1" \
      RELEASE_TMP="/tmp/board${n}" \
      PHX_SERVER= \
      "${BIN}" daemon
}

start_headless 2
start_headless 3

# board1 is the web node and the container's foreground process.
mkdir -p /tmp/board1
export RELEASE_NODE="board1@127.0.0.1"
export RELEASE_TMP="/tmp/board1"
export PHX_SERVER=true
export PORT="${PORT:-8080}"
exec "${BIN}" start
