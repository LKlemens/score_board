defmodule ScoreBoard.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # LocalEpmd discovers every node registered with the local epmd daemon
    topologies = [local: [strategy: Cluster.Strategy.LocalEpmd]]

    children = [
      ScoreBoardWeb.Telemetry,
      {Cluster.Supervisor, [topologies, [name: ScoreBoard.ClusterSupervisor]]},
      {DNSCluster, query: Application.get_env(:score_board, :dns_cluster_query) || :ignore},
      # Two PubSub instances side by side: the default (PG2) one carries
      # transient traffic — LiveView internals and the boards' local UI
      # notifications — while the EchoPubSub one carries the domain events
      # that need at-least-once delivery. A blip halts only the event
      # stream; the UI stays live.
      Supervisor.child_spec({Phoenix.PubSub, name: ScoreBoard.PubSub}, id: ScoreBoard.PubSub),
      # buffer_size 20 keeps the overflow demo reachable: hold a blip past
      # ~20 events and the producer expires this node's cursor
      Supervisor.child_spec(
        {Phoenix.PubSub,
         name: ScoreBoard.EchoPubSub, adapter: EchoPubSub, pool_size: 1, buffer_size: 20},
        id: ScoreBoard.EchoPubSub
      ),
      {Task.Supervisor, name: ScoreBoard.TaskSupervisor},
      {Horde.Registry, name: ScoreBoard.MatchRegistry, keys: :unique, members: :auto},
      # The board must exist before Horde can place match processes here:
      # a restarted match reads this node's board in init/1 to restore its
      # score. It also subscribes to PubSub, so it starts after that too.
      ScoreBoard.Board,
      {Horde.DynamicSupervisor,
       name: ScoreBoard.MatchSupervisor, strategy: :one_for_one, members: :auto},
      # One-shot seeding of configured matches; a :temporary Task, so a
      # boot race with a peer node seeding the same ids cannot cycle the tree
      {Task, &ScoreBoard.Matches.create_prefilled/0},
      # Start to serve requests, typically the last entry
      ScoreBoardWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ScoreBoard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ScoreBoardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
