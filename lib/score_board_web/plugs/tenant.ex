defmodule ScoreBoardWeb.Plugs.Tenant do
  @moduledoc """
  Mints a stable per-browser tenant id in the session on first visit.

  The `ScoreLive` mount reads `session["tenant"]` and asks `ScoreBoard.Lanes`
  for that tenant's lane, so a reconnecting browser resumes the same isolated
  scoreboard. The id is a random, signed-cookie-backed string - not a secret,
  just a handle.
  """
  import Plug.Conn

  @key "tenant"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case get_session(conn, @key) do
      nil -> put_session(conn, @key, mint())
      _tenant -> conn
    end
  end

  defp mint, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64()
end
