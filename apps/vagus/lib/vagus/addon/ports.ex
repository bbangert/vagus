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

  A host port the host owns (`reserved_host_ports/0`) is dropped to `nil` —
  declared but unpublished — wherever it comes from. `sanitize/2` refuses one
  posted by a caller, but the add-on's **own `config.yaml` default** never goes
  through `sanitize/2` at all: it arrives here straight from `Config.parse/1`.
  Filtering only the posted path would have meant an add-on could claim
  Vagus's API port simply by declaring it as its default and never posting
  anything (review round 2). The rule is a property of the host, so it belongs
  on every path into the container spec, not just the caller-facing one.
  """
  @spec effective(Config.t(), t()) :: t()
  def effective(%Config{ports: config_ports}, overrides)
      when is_map(config_ports) and is_map(overrides) do
    if map_size(config_ports) == 0 do
      drop_reserved(overrides)
    else
      config_ports
      |> Map.new(fn {port, default} -> {port, Map.get(overrides, port, default)} end)
      |> drop_reserved()
    end
  end

  # Unpublish rather than raise: `effective/2` is on the container-start path,
  # where a hard failure would make an add-on that ships a reserved default
  # permanently uninstallable instead of merely unpublished on that port.
  defp drop_reserved(ports) do
    reserved = reserved_host_ports()

    Map.new(ports, fn
      {port, host_port} when is_integer(host_port) ->
        if host_port in reserved, do: {port, nil}, else: {port, host_port}

      {port, host_port} ->
        {port, host_port}
    end)
  end

  @doc """
  Narrows a posted `network` map to the overrides worth persisting: only ports
  the config declares, only `nil` or a valid port number.

  `{:error, message}` when a value isn't a port at all — upstream drops
  *unknown keys* silently but its schema still rejects a non-port *value*, and
  a 400 there is far kinder than persisting `"eighty"` and failing at
  container start.

  Also `{:error, _}` for the handful of host ports the *host* owns
  (`reserved_host_ports/0`). That check is stricter than upstream and it is
  deliberate: since the 2026-07-29 audit's A3, `POST /addons/self/options` is
  reachable by the add-on itself (upstream's `api_bypass`), and
  `POST /addons/self/restart` alongside it — so without a floor here an add-on
  could rebind one of its own declared ports onto Vagus's API port or Core's
  and race the real listener, entirely self-service. Which host ports are
  spoken for is a property of the host, not something an add-on's own
  `config.yaml` gets a say in.

  Note this is NOT a blanket privileged-port ban. Plenty of legitimate add-ons
  publish on 53, 443, 1883 (AdGuard, NGINX, Mosquitto), so a `< 1024` rule
  would break real configurations for no gain — only the ports Vagus and Core
  actually listen on are refused.
  """
  @spec sanitize(Config.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def sanitize(%Config{ports: config_ports}, posted) when is_map(posted) do
    reserved = reserved_host_ports()

    Enum.reduce_while(posted, {:ok, %{}}, fn {port, host_port}, {:ok, acc} ->
      cond do
        not Map.has_key?(config_ports, port) ->
          {:cont, {:ok, acc}}

        not valid_host_port?(host_port) ->
          {:halt, {:error, "network port #{port} must be null or 0-#{@max_port}"}}

        host_port in reserved ->
          {:halt, {:error, "host port #{host_port} is reserved by the system"}}

        true ->
          {:cont, {:ok, Map.put(acc, port, host_port)}}
      end
    end)
  end

  # Home Assistant Core's two host ports. A supervised install binds 80
  # (`SUPERVISOR_DEFAULT_PORT`) and falls back to 8123
  # (`_DEFAULT_CONFIG_LEGACY_PORT`) when that bind fails, keeping the fallback
  # in its config store afterwards — so both are Core's, and 8123 is a state a
  # real device reaches rather than a historical value.
  #
  # 80 is spoken for twice over: it is also the port the add-on contract
  # hardwires (`http://supervisor/`, and Core's bare `SUPERVISOR` env), served
  # on the bridge anchor by `Vagus.Network.Nat`'s DNAT onto the API's internal
  # port rather than by a listener. Publishing a container port on host 80
  # collides with Core's own wildcard bind either way, which is why it is
  # named here as Core's.
  #
  # Core's port is user-settable via `POST /core/options`, and since the
  # socket transport `Vagus.Core.HttpConfig` even caches the port Core reports
  # it is serving — but these stay constants: reading that cache would put a
  # `GenServer.call` on the container-start path (`effective/2`) for a
  # nuisance case. An add-on squatting a *moved* Core port is a nuisance,
  # whereas squatting Vagus's own API port is how it would sit in front of the
  # Supervisor API itself, and that one is read from config exactly.
  @core_port 80
  @core_legacy_port 8123

  @doc """
  Host ports an add-on may not bind: Vagus's own Supervisor-API listener plus
  Core's port (`#{@core_port}`) and its legacy fallback (`#{@core_legacy_port}`).

  The API port is read from config at call time rather than baked in at
  compile time. Note it is the *internal* port the listener actually holds
  (`:api_port`, 8888), which is not the port add-ons dial: they reach the API
  at `http://supervisor/`, i.e. 80 on the bridge anchor, through
  `Vagus.Network.Nat`'s DNAT. Both ends of that rewrite are reserved — 80 as
  Core's above, the internal port here.
  """
  @spec reserved_host_ports() :: [non_neg_integer()]
  def reserved_host_ports, do: reserved_host_ports(Application.get_env(:vagus, :api_port, 8888))

  @doc """
  `reserved_host_ports/0` for an explicit API port.

  The arity exists so a test can vary the API port without `put_env` on the
  global app env — which an `async: true` file cannot do. Asserting
  `reserved_host_ports()` against `Application.get_env(:vagus, :api_port, …)`
  is tautological: both read the same key with the same default, so a
  hard-coded constant here would satisfy it and a configured port would go
  untested. That was the shape of the first test written for this, and it is
  why the arity is here.
  """
  @spec reserved_host_ports(term()) :: [non_neg_integer()]
  def reserved_host_ports(api_port) do
    [api_port, @core_port, @core_legacy_port]
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp valid_host_port?(nil), do: true
  defp valid_host_port?(value) when is_integer(value), do: value >= 0 and value <= @max_port
  defp valid_host_port?(_value), do: false
end
