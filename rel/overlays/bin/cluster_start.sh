#!/bin/sh
# Boots one isolated 3-node cluster inside a single fly machine.
#
# board2/3 headless, board1 serves HTTP in the foreground. Loopback-only, so
# other machines never cluster in. Host list: config/prod.exs - keep in step.
set -eu

RELEASE="${RELEASE_NAME:-score_board}"
BIN="/app/bin/${RELEASE}"

# Shared cookie is safe: loopback-only.
export RELEASE_DISTRIBUTION=name
export RELEASE_COOKIE="${RELEASE_COOKIE:-score-board-demo-cookie}"

export ERL_EPMD_ADDRESS=127.0.0.1
export ERL_AFLAGS="${ERL_AFLAGS:-} -kernel inet_dist_use_interface {127,0,0,1}"

start_headless() {
  n="$1"
  mkdir -p "/tmp/board${n}"
  env -u PHX_SERVER \
      RELEASE_NODE="board${n}@127.0.0.1" \
      RELEASE_TMP="/tmp/board${n}" \
      "${BIN}" daemon
}

start_headless 2
start_headless 3

mkdir -p /tmp/board1
export RELEASE_NODE="board1@127.0.0.1"
export RELEASE_TMP="/tmp/board1"
export PHX_SERVER=true
export PORT="${PORT:-8080}"
exec "${BIN}" start
