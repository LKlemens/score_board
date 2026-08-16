defmodule ScoreBoard.Blip do
  @moduledoc """
  Simulated network blip, backed by echo_pubsub's fault injection.

  While a blip is on, this node is partitioned in both directions: its
  EchoPubSub worker rejects incoming batches *below the ack*, and its
  producer stops delivering outgoing ones. Neither side drops anything -
  remote producers keep their cursors and buffer, this node buffers its
  own writes, and both replay in order once the blip ends. Hold a blip
  long enough to overflow a ring buffer and the lagging node gets
  `{:cursor_expired, node}` instead, the signal to reload from a source of
  truth.
  """

  @doc "Starts rejecting incoming and outgoing PubSub batches on this node."
  @spec on() :: :ok
  def on, do: Application.put_env(:echo_pubsub, :fault_injection, :error)

  @doc "Ends the simulated blip; buffered batches replay in order."
  @spec off() :: :ok
  def off, do: Application.put_env(:echo_pubsub, :fault_injection, :ok)

  @doc "Whether this node is currently partitioned from PubSub."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:echo_pubsub, :fault_injection, :ok) == :error
end
