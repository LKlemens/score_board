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

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
