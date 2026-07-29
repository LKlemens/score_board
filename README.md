# ScoreBoard

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Running the two-node demo

Start two named nodes in separate terminals (libcluster's Gossip strategy
discovers and connects them automatically):

```sh
PORT=4000 iex --sname board1 -S mix phx.server
PORT=4001 iex --sname board2 -S mix phx.server
```

Verify clustering from either IEx shell — the peer should be listed:

```elixir
iex(board1@host)> Node.list()
[:board2@host]
```

Then open [`localhost:4000`](http://localhost:4000) and
[`localhost:4001`](http://localhost:4001) side by side.

### Demo script

Each match runs as a single process somewhere in the cluster (placed by
Horde) — the source of truth for its score. Each node keeps its own derived
board in ETS, fed by PubSub events.

1. Create a few matches from either browser tab — they appear on both, and
   the *Owner node* column shows where each match process actually lives
   (creating on `board1` does not mean owning on `board1`).
2. Click goal buttons from either tab: the goal is routed to the owning
   match process, wherever it runs, and every node's board converges.
3. Failover: kill the node that owns a match (`Ctrl+C` twice in its
   terminal). Horde restarts the match on the survivor, which re-seeds the
   score from the survivor's derived board — refresh the surviving tab and
   the match is still there, owned by the survivor, score intact. (If the
   survivor's board had missed events, the restored score is its best
   available view — there is no persistence layer.)

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
