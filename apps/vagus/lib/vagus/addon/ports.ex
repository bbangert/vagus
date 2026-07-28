defmodule Vagus.Addon.Ports do
  @moduledoc """
  The add-on port map the frontend's Network card edits: `config.yaml`'s
  declared ports, overlaid with the user's persisted host-port overrides.

  Two rules, both upstream's (`supervisor/apps/app.py`'s `ports` property and
  its setter), and both easy to get subtly wrong:

    * **The config declares the set, the user only sets the values.** Every
      port in `config.ports` stays visible even when the user remapped one of
      them, so an optional port left unpublished (`null`) still shows in the
      card, and a port a later add-on version *adds* appears with its new
      default rather than vanishing behind a stale override.
    * **An override for a port the config doesn't declare is dropped, not an
      error.** The frontend only ever posts back keys it was given, so an
      unknown key means the add-on's config moved on — silently forgetting it
      is what keeps a stale browser tab from writing junk into the state file.

  An add-on that declares no ports has nothing to overlay, so its overrides
  pass through untouched: that mirrors upstream returning the persisted map
  whole when `config_ports is None`.
  """

  alias Vagus.Addon.Config

  @typedoc "`%{\"<port>/<proto>\" => host_port | nil}`."
  @type t :: %{optional(String.t()) => nil | non_neg_integer()}

  @max_port 65_535

  @doc """
  The effective map to publish and to hand the container runtime: `overrides`
  overlaid on `config.ports`, restricted to the ports the config declares.
  """
  @spec effective(Config.t(), t()) :: t()
  def effective(%Config{ports: config_ports}, overrides)
      when is_map(config_ports) and is_map(overrides) do
    if map_size(config_ports) == 0 do
      overrides
    else
      Map.new(config_ports, fn {port, default} ->
        {port, Map.get(overrides, port, default)}
      end)
    end
  end

  @doc """
  Narrows a posted `network` map to the overrides worth persisting: only ports
  the config declares, only `nil` or a valid port number.

  `{:error, message}` when a value isn't a port at all — upstream drops
  *unknown keys* silently but its schema still rejects a non-port *value*, and
  a 400 there is far kinder than persisting `"eighty"` and failing at
  container start.
  """
  @spec sanitize(Config.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def sanitize(%Config{ports: config_ports}, posted) when is_map(posted) do
    Enum.reduce_while(posted, {:ok, %{}}, fn {port, host_port}, {:ok, acc} ->
      cond do
        not Map.has_key?(config_ports, port) -> {:cont, {:ok, acc}}
        valid_host_port?(host_port) -> {:cont, {:ok, Map.put(acc, port, host_port)}}
        true -> {:halt, {:error, "network port #{port} must be null or 0-#{@max_port}"}}
      end
    end)
  end

  defp valid_host_port?(nil), do: true
  defp valid_host_port?(value) when is_integer(value), do: value >= 0 and value <= @max_port
  defp valid_host_port?(_value), do: false
end
