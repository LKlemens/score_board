defmodule ScoreBoardWeb.PageController do
  use ScoreBoardWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
