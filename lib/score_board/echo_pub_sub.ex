defmodule ScoreBoard.EchoPubSub do
  @moduledoc """
  The at-least-once event bus: a thin facade over the EchoPubSub-backed
  `Phoenix.PubSub` instance. This module's name doubles as the instance
  name registered in the supervision tree.

  Use it for domain events that must not be lost; transient traffic
  (LiveView internals, local UI notifications) stays on the default
  `ScoreBoard.PubSub` instance.
  """

  @doc "Broadcasts `message` on `topic` with at-least-once delivery."
  @spec broadcast(String.t(), term()) :: :ok | {:error, term()}
  def broadcast(topic, message) do
    Phoenix.PubSub.broadcast(__MODULE__, topic, message)
  end

  @doc """
  Subscribes the caller to `topic`.

  Besides the topic's own events, subscribers also receive
  `{:cursor_expired, node}` when this node fell off a remote producer's
  ring buffer - the signal to reload from a source of truth.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(topic) do
    Phoenix.PubSub.subscribe(__MODULE__, topic)
  end
end
