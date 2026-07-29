# List available recipes
default:
    @just --list

# Install deps and build assets
setup:
    mix setup

# Run the test suite
test:
    mix test

# Start a named demo node: just node board3 4002
node name port:
    PORT={{ port }} iex --sname {{ name }} -S mix phx.server

# Start demo node board1 on port 4000
board1:
    @just node board1 4000

# Start demo node board2 on port 4001 (in a second terminal)
board2:
    @just node board2 4001
