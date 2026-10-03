defmodule ScoreBoard.TelegramTest do
  use ExUnit.Case, async: false

  alias ScoreBoard.Telegram

  setup do
    original = Application.get_env(:score_board, :telegram)
    on_exit(fn -> Application.put_env(:score_board, :telegram, original) end)
    :ok
  end

  test "unconfigured, it is off and skips sending" do
    Application.put_env(:score_board, :telegram, bot_token: nil, chat_id: nil)

    refute Telegram.configured?()
    assert Telegram.notify("hello") == :skipped
  end

  test "a token without a chat id is still off" do
    Application.put_env(:score_board, :telegram, bot_token: "t", chat_id: nil)

    refute Telegram.configured?()
  end

  test "both values present turns it on" do
    Application.put_env(:score_board, :telegram, bot_token: "t", chat_id: "1")

    assert Telegram.configured?()
  end
end
