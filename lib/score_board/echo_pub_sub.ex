defmodule ScoreBoard.EchoPubSub do
  @moduledoc """
  Thin facade over an EchoPubSub-backed `Phoenix.PubSub` instance.

  Each tenant lane runs its own instance (see `ScoreBoard.Lane.pubsub/1`), so
  the instance is passed in rather than hardcoded. Use it for domain events
  that must not be lost; transient traffic (LiveView internals, local UI
  notifications) stays on the shared `ScoreBoard.PubSub` instance.
  """

  @doc "Broadcasts `message` on `topic` of `pubsub` with at-least-once delivery."
  @spec broadcast(atom(), String.t(), term()) :: :ok | {:error, term()}
  def broadcast(pubsub, topic, message) do
    Phoenix.PubSub.broadcast(pubsub, topic, message)
  end

  @doc """
  Subscribes the caller to `topic` of `pubsub`.

  Besides the topic's own events, subscribers also receive
  `{:cursor_expired, node}` when this node fell off a remote producer's
  ring buffer - the signal to reload from a source of truth.
  """
  @spec subscribe(atom(), String.t()) :: :ok | {:error, term()}
  def subscribe(pubsub, topic) do
    Phoenix.PubSub.subscribe(pubsub, topic)
  end
end
