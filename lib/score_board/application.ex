defmodule ScoreBoard.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Gossip discovers peer nodes on the local network via UDP multicast, so two
    # dev nodes cluster automatically without configured node lists.
    topologies = [gossip: [strategy: Cluster.Strategy.Gossip]]

    children = [
      ScoreBoardWeb.Telemetry,
      {Cluster.Supervisor, [topologies, [name: ScoreBoard.ClusterSupervisor]]},
      {DNSCluster, query: Application.get_env(:score_board, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ScoreBoard.PubSub},
      {Task.Supervisor, name: ScoreBoard.TaskSupervisor},
      {Horde.Registry, name: ScoreBoard.MatchRegistry, keys: :unique, members: :auto},
      # The board must exist before Horde can place match processes here:
      # a restarted match reads this node's board in init/1 to restore its
      # score. It also subscribes to PubSub, so it starts after that too.
      ScoreBoard.Board,
      {Horde.DynamicSupervisor,
       name: ScoreBoard.MatchSupervisor, strategy: :one_for_one, members: :auto},
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
