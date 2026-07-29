# ScoreBoard

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Running the two-node demo

Start two named nodes in separate terminals (libcluster's LocalEpmd strategy
discovers and connects all local nodes automatically — no multicast needed):

```sh
just board 1
just board 2
```

Add as many as you like (`just board 3`, ...) — node `boardN` serves on port
`4000+N-1`. Without `just`:

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

The app runs **two PubSub instances side by side** — the incremental
adoption story: `ScoreBoard.PubSub` (default PG2 adapter) keeps carrying
transient traffic (LiveView internals, the boards' local UI notifications),
while `ScoreBoard.EchoPubSub` (EchoPubSub adapter) carries only the domain
events that must not be lost. During a blip the event stream freezes and
later replays — but the UI stays fully live, because it rides the other
instance.

Every node's page shows *all* nodes' boards side by side, next to the true
score held by each match process: one column per node, read over `:erpc` so
the display stays reliable even when PubSub is degraded. A red cell means
that node's board disagrees with the true score (stale or missing data);
an *offline* badge marks an unreachable node.

1. Create a few matches from either browser tab — they appear in both, and
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
4. Network blip (EchoPubSub): press *Go offline* on node B — its worker now
   rejects incoming batches *below the ack*, so remote producers buffer and
   retry. **Blip a node that does not own the match you score**: events for
   locally-owned matches are dispatched without crossing the network, so
   blipping the owner shows nothing (check the *Owner* column — after a
   fresh start the first-booted node owns all prefilled matches). Score goals on node A: B's column turns red and freezes on every
   page while A's advances. Press *Back online* — the buffered events
   replay **in order** and B converges. (Plain PG2 would have lost them
   forever.) The *1ms blip* and *5s outage* buttons do the same with
   automatic recovery.
5. Buffer overflow: stay offline on B past ~20 events scored on A — B's
   cursor falls off A's ring buffer (`buffer_size: 20`). On reconnect B
   receives `{:cursor_expired, node}` instead of a replay and the board
   reloads everything from the match processes — converged either way,
   just via the documented recovery path.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
