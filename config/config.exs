# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :score_board,
  ecto_repos: [ScoreBoard.Repo],
  generators: [timestamp_type: :utc_datetime]

# Dashboard persistence is opt-in: no url, no repo, counters stay in memory.
config :score_board, ScoreBoard.Repo, url: nil
config :score_board, :stats_sample_ms, :timer.minutes(1)

# Phone alerts; both values come from the environment in prod.
config :score_board, :telegram, bot_token: nil, chat_id: nil

# The tenant pool: how many isolated lanes are pre-started, and the ring
# buffer each lane's event bus keeps (the overflow-reload demo needs a small
# one). A lane idle past :lane_ttl_ms goes back to the pool.
config :score_board, :lane_count, 200
config :score_board, :lane_buffer_size, 5
config :score_board, :lane_ttl_ms, :timer.minutes(5)
config :score_board, :lane_sweep_ms, :timer.seconds(30)

# Compile echo_pubsub's fault-injection hook into this app's build so the
# UI blip button can make the local worker reject incoming batches
config :echo_pubsub, :enable_fault_injection, true

# Configure the endpoint
config :score_board, ScoreBoardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ScoreBoardWeb.ErrorHTML, json: ScoreBoardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ScoreBoard.PubSub,
  live_view: [signing_salt: "+1wFcjZl"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :score_board, ScoreBoard.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  score_board: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  score_board: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Node discovery; prod overrides it.
config :score_board, :topologies, local: [strategy: Cluster.Strategy.LocalEpmd]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
