defmodule ScoreBoard.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Reap dead nodes in ~5s instead of the ~60s default so stale columns clear.
    :net_kernel.set_net_ticktime(5)

    # epmd listing in dev/test, fixed hosts in prod.
    topologies = Application.fetch_env!(:score_board, :topologies)

    children = [
      ScoreBoardWeb.Telemetry,
      {Cluster.Supervisor, [topologies, [name: ScoreBoard.ClusterSupervisor]]},
      {DNSCluster, query: Application.get_env(:score_board, :dns_cluster_query) || :ignore},
      # The shared, transient PubSub (PG2): LiveView internals and each lane
      # board's local UI notifications. Per-lane at-least-once event buses live
      # under the lane pool instead.
      {Phoenix.PubSub, name: ScoreBoard.PubSub},
      {Horde.Registry, name: ScoreBoard.MatchRegistry, keys: :unique, members: :auto},
      {
        Horde.DynamicSupervisor,
        name: ScoreBoard.MatchSupervisor,
        strategy: :one_for_one,
        members: :auto,
        distribution_strategy: ScoreBoard.RoundRobinDistribution,
        process_redistribution: :active
      },
      # Blocks 500ms so Horde's registries sync the existing cluster before boot.
      {ScoreBoard.BootBarrier, 500},
      # The tenant lane pool: per lane, an isolated event bus + DB replica +
      # board, plus the tracker that assigns a free lane per browser cookie.
      ScoreBoard.LanePool,
      # Start to serve requests, typically the last entry
      ScoreBoardWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ScoreBoard.Supervisor]
    Supervisor.start_link(repo() ++ children, opts)
  end

  # Postgres is optional and only backs the dashboard's history: without a
  # configured url the repo stays down and the counters are memory-only.
  defp repo do
    if Application.get_env(:score_board, ScoreBoard.Repo)[:url],
      do: [ScoreBoard.Repo],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ScoreBoardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
