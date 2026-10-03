defmodule ScoreBoard.Telegram do
  @moduledoc """
  Pushes a short message to a Telegram chat through the bot API.

  Off unless both `:bot_token` and `:chat_id` are configured (from
  `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in prod), so dev, test and an
  unconfigured deploy simply skip. Sending happens in a supervised task: an
  alert must never block or crash its caller.
  """

  require Logger

  @api "https://api.telegram.org"

  @doc "Whether a bot token and chat id are configured."
  @spec configured?() :: boolean()
  def configured?, do: bot_token() != nil and chat_id() != nil

  @doc """
  Sends `text` to the configured chat.

  Returns `:skipped` when Telegram is not configured, `:ok` once the send has
  been handed to a task.
  """
  @spec notify(String.t()) :: :ok | :skipped
  def notify(text) do
    if configured?() do
      Task.Supervisor.start_child(ScoreBoard.TaskSupervisor, fn -> post(text) end)
      :ok
    else
      :skipped
    end
  end

  defp post(text) do
    url = "#{@api}/bot#{bot_token()}/sendMessage"

    case Req.post(url, json: %{chat_id: chat_id(), text: text}, receive_timeout: 5_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> Logger.warning("Telegram refused the alert: HTTP #{status}")
      {:error, reason} -> Logger.warning("Telegram alert failed: #{inspect(reason)}")
    end
  end

  defp bot_token, do: Application.get_env(:score_board, :telegram)[:bot_token]
  defp chat_id, do: Application.get_env(:score_board, :telegram)[:chat_id]
end
