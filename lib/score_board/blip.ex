defmodule ScoreBoard.Blip do
  @moduledoc """
  Simulated network blip for one tenant lane, backed by echo_pubsub's
  per-group fault injection.

  While a lane is blipped, this node is partitioned in both directions on
  that lane's event bus: its worker rejects incoming batches and its producer
  stops delivering outgoing ones. Neither side drops anything - remote
  producers keep their cursors and buffer, this node buffers its own writes,
  and both replay in order once the blip ends. Hold a blip long enough to
  overflow a ring buffer and the lagging node gets `{:cursor_expired, node}`
  instead, the signal to reload from a source of truth.

  The flag is keyed by the lane's pubsub group, so one lane going offline
  never touches another.
  """

  alias EchoPubSub.FaultInjection
  alias ScoreBoard.Lane

  @doc "Starts rejecting this lane's incoming and outgoing batches on this node."
  @spec on(Lane.id()) :: :ok
  def on(lane), do: FaultInjection.put(Lane.group(lane), :error)

  @doc "Ends the lane's blip; buffered batches replay in order."
  @spec off(Lane.id()) :: :ok
  def off(lane), do: FaultInjection.put(Lane.group(lane), :ok)

  @doc "Whether this lane is currently partitioned on this node."
  @spec enabled?(Lane.id()) :: boolean()
  def enabled?(lane), do: not FaultInjection.ok?(Lane.group(lane))
end
