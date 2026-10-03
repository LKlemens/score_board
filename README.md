# ScoreBoard

A live demo of [EchoPubSub](https://github.com/LKlemens/echo_pubsub): a three-node
BEAM cluster where you can take a node offline mid-game and watch the events it
missed replay in order when it comes back.

![Scoreboard demo](https://github.com/LKlemens/score_board/releases/download/media-v1/demo.gif)

Live at [scoreboard-pool.fly.dev](https://scoreboard-pool.fly.dev). Every browser
gets its own isolated cluster, so several people can break the demo at once
without touching each other's state.

What the recording shows:

* **One board per node**, next to the true score held by the match process. A
  match is a single process placed by Horde; the *Owner* column says where it
  runs. Boards are read over `:erpc`, so the display stays honest even when the
  event bus is degraded.
* **Take a node offline** - its column freezes and turns red while the others
  advance. Nothing is dropped: the other nodes buffer for it, and the orange box
  counts what is held for each lagging peer.
* **Bring it back** - the backlog replays in order, drawn as a convoy of dots.
  The board converges. Plain PubSub would have lost those events for good.
* **Overflow the ring buffer** (it holds 5) and the box turns red: the peer's
  cursor fell off the end, so it gets `{:cursor_expired, node}` instead of a
  replay and reloads from the source of truth. Converged either way.

## Running it locally

```sh
mix setup
just board 1   # then `just board 2`, `just board 3` in their own terminals
```

Node `boardN` serves on port `4000+N-1`; libcluster's LocalEpmd strategy connects
them automatically. Without `just`:

```sh
PORT=4000 iex --sname board1 -S mix phx.server
```

Open the ports side by side and score a goal.

## How it fits together

The app runs **two PubSub instances side by side** - the incremental adoption
story. `ScoreBoard.PubSub` (the default PG2 adapter) carries transient traffic:
LiveView internals and the boards' local UI notifications. EchoPubSub carries
only the domain events that must not be lost. During a blip the event stream
freezes and later replays, while the UI stays fully live, because it rides the
other instance.

Each node keeps its own derived board in ETS, fed by those events, and its own
replica of `ScoreBoard.DB` - the store a restarted match reads its score back from.
