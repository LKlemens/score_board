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
      # transient traffic - LiveView internals and the boards' local UI
      # notifications - while the EchoPubSub one carries the domain events
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
      {Horde.Registry, name: ScoreBoard.MatchRegistry, keys: :unique, members: :auto},
      # Matches start before the board; the board's boot reload then pulls
      # all scores from the DB in one read
      {Horde.DynamicSupervisor,
       name: ScoreBoard.MatchSupervisor,
       strategy: :one_for_one,
       members: :auto,
       distribution_strategy: ScoreBoard.RoundRobinDistribution,
       process_redistribution: :active},
      {Horde.DynamicSupervisor,
       name: ScoreBoard.DBSupervisor,
       strategy: :one_for_one,
       members: :auto,
       process_redistribution: :passive},
      # Bring the one cluster-wide DB up, then claim one match for this node
      Supervisor.child_spec(
        {Task,
         fn ->
           ScoreBoard.DB.ensure_started() |> dbg()

           if Application.get_env(:score_board, :auto_claim_match, true) do
             ScoreBoard.Matches.claim_one()
           end
         end},
        id: :boot
      ),
      ScoreBoard.Board,
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
