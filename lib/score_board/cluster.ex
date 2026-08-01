defmodule ScoreBoard.Cluster do
  @moduledoc """
  This node's snapshot for the cluster page: derived board, blip state,
  and the echo producer's per-peer backlog - messages written but not yet
  acknowledged by each peer, i.e. the bucket that drains once the peer's
  connection is back.
  """

  alias ScoreBoard.Blip
  alias ScoreBoard.Board
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  # pool_size is 1, so the single producer keeps the plain adapter name.
  @producer ScoreBoard.EchoPubSub.Adapter.Producer

  @type snapshot :: %{
          scores: %{Matches.match_id() => Match.score()},
          blip: boolean(),
          pending: %{node() => non_neg_integer()},
          capacity: pos_integer() | nil
        }

  @doc "Everything the cluster page needs to render this node."
  @spec snapshot() :: snapshot()
  def snapshot do
    producer = producer_state()

    %{
      scores: Board.scores(),
      blip: Blip.enabled?(),
      pending: pending(producer),
      capacity: capacity(producer)
    }
  end

  # :sys.get_state/2 is a debug API - acceptable for a demo dashboard, and
  # guarded so a busy or restarting producer never breaks rendering.
  defp producer_state do
    :sys.get_state(@producer, 300)
  catch
    _kind, _reason -> nil
  end

  defp pending(nil), do: %{}

  defp pending(state) do
    state.read_cursors
    # The local cursor advances on every flush; only peers can lag.
    |> Map.delete(node())
    |> Map.new(fn {peer, cursor} -> {peer, max(state.write_cursor - cursor, 0)} end)
  end

  defp capacity(nil), do: nil
  defp capacity(state), do: :array.size(state.buffer)
end
