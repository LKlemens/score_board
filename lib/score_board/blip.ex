defmodule ScoreBoard.Blip do
  @moduledoc """
  Simulated network blip, backed by echo_pubsub's fault injection.

  While a blip is on, this node's EchoPubSub worker rejects incoming
  batches *below the ack*: remote producers keep their cursors, buffer the
  messages, and replay them in order once the blip ends. Nothing is
  dropped at the application level - hold a blip long enough to overflow a
  producer's ring buffer and this node gets `{:cursor_expired, node}`
  instead, the signal to reload from a source of truth.
  """

  @doc "Starts rejecting incoming PubSub batches on this node."
  @spec on() :: :ok
  def on, do: Application.put_env(:echo_pubsub, :fault_injection, :error)

  @doc "Ends the simulated blip; buffered batches replay in order."
  @spec off() :: :ok
  def off, do: Application.put_env(:echo_pubsub, :fault_injection, :ok)

  @doc "Whether this node is currently rejecting incoming batches."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:echo_pubsub, :fault_injection, :ok) == :error
end
