defmodule ScoreBoard.Cluster do
  @moduledoc """
  One lane's snapshot for the cluster page: that lane's derived board, blip
  state, and the lane producer's per-peer backlog - messages written but not
  yet acknowledged by each peer, i.e. the bucket that drains once the peer's
  connection is back.
  """

  alias ScoreBoard.Blip
  alias ScoreBoard.Board
  alias ScoreBoard.Lane
  alias ScoreBoard.Match
  alias ScoreBoard.Matches

  @type snapshot :: %{
          scores: %{Matches.match_id() => Match.score()},
          blip: boolean(),
          pending: %{node() => non_neg_integer()},
          capacity: pos_integer() | nil
        }

  @doc "Everything the cluster page needs to render this node for `lane`."
  @spec snapshot(Lane.id()) :: snapshot()
  def snapshot(lane) do
    producer = producer_state(Lane.producer(lane))

    %{
      scores: Board.scores(lane),
      blip: Blip.enabled?(lane),
      pending: pending(producer),
      capacity: capacity(producer)
    }
  end

  # :sys.get_state/2 is a debug API - acceptable for a demo dashboard, and
  # guarded so a busy or restarting producer never breaks rendering.
  defp producer_state(name) do
    :sys.get_state(name, 300)
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
