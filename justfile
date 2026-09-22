# List available recipes
default:
    @just --list

# Install deps and build assets
setup:
    mix setup

# Run the test suite
test:
    mix test

# Start demo node boardN on port 4000+N-1, e.g. `just board 1`, `just board 2`, ...
board n:
    PORT=$((3999 + {{ n }})) iex --sname board{{ n }} -S mix phx.server

# Start a node with a custom name and port: just node scores 5000
node name port:
    PORT={{ port }} iex --sname {{ name }} -S mix phx.server

# Deploy to fly.io (one machine = one 3-node cluster). One-time setup in DEPLOY.md.
deploy:
    fly deploy --ha=false
