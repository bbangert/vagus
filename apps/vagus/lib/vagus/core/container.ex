defmodule Vagus.Core.Container do
  @moduledoc """
  Pure builder for the HA Core container's Engine-API
  `POST /containers/create` body — the device-proven real-Supervisor-parity
  run spec settled during the bluetooth work (see
  `.claude/plans/vagus-core-lifecycle/research/supervisor-semantics.md`,
  mirroring upstream `supervisor/docker/homeassistant.py`).

  This is Core's OWN spec builder, deliberately separate from
  `Vagus.Addon.Backend.Container.build_config/1`: the add-on builder
  hard-stamps `Privileged: false` / `OomScoreAdj: 200` as a cross-cutting
  add-on security invariant, and Core's `Privileged: true` spec must not
  reuse (and thereby weaken) that seam.

  `create_config/2` has no side effects beyond its `Token.get/0` default —
  no processes, no Engine-API calls. `Vagus.Core.Lifecycle` (a later phase)
  is what actually creates/starts/stops containers from this config.

  ## Deliberate v1 omissions vs. upstream `docker/homeassistant.py`

  * **`/etc/machine-id` bind** — Nerves' `/etc` is read-only firmware, there
    is no writable machine-id file to bind in.
  * **`/run/supervisor` bind** — upstream mounts a unix socket for Core's
    in-process Supervisor API; Vagus has no such socket (Core talks to
    Vagus over HTTP/`:8123`-adjacent host networking instead), so there is
    nothing to bind.
  * **`Init` and `SecurityOpt: ["seccomp=unconfined"]`** — not part of the
    device-proven recipe; omitted rather than guessed at.
  * **landingpage** — upstream installs a de-privileged placeholder image
    when neither a Core container nor image exists yet. Vagus's device
    class ships Core pre-provisioned, so landingpage has no v1 analog;
    "image missing" is left as an error/repair state for a later phase.
  * **per-machine image** — upstream selects
    `ghcr.io/home-assistant/{machine}-homeassistant`; v1 pins the generic
    `ghcr.io/home-assistant/home-assistant` image for every device class.

  ## Deliberate v1 deviations (kept, not omitted — see plan "Locked decisions")

  * `RestartPolicy: unless-stopped` — upstream owns Core restarts itself
    (container/API watchdogs); Vagus v1 has no Core watchdog yet, so the
    engine's own restart policy covers the crash-loop case until one lands.
  * No `:8888`-style port suffix on the `SUPERVISOR`/`HASSIO` env IPs —
    port 80 is implicit on this address (Vagus's Bandit listener), and an
    explicit `:8888` suffix was device-proven to break Core during the
    bluetooth work.
  """

  alias Vagus.API.Token
  alias Vagus.Network

  @image_repo "ghcr.io/home-assistant/home-assistant"
  @default_name "homeassistant"
  @default_tz "UTC"

  @doc "The fixed Core container name (`homeassistant`) — upstream parity."
  @spec name() :: String.t()
  def name do
    Application.get_env(:vagus, :core_container) || @default_name
  end

  @doc "The named docker volume holding Core's /config (see mounts/0)."
  @spec config_volume() :: String.t()
  def config_volume, do: "vagus-core-config"

  @doc "The Core image reference for `version`, e.g. `ghcr.io/home-assistant/home-assistant:2026.7.0`."
  @spec image(String.t()) :: String.t()
  def image(version) when is_binary(version), do: @image_repo <> ":" <> version

  @doc """
  Builds the Engine-API `POST /containers/create` body for HA Core at
  `version`.

  Options:

    * `:token` - the Supervisor/HASSIO bearer token Core authenticates
      back to Vagus with. Defaults to `Vagus.API.Token.get/0`; injectable
      so tests never touch the real persisted/on-disk token.
    * `:tz` - the `TZ` env value. Defaults to `"UTC"`.
  """
  @spec create_config(String.t(), keyword()) :: map()
  def create_config(version, opts \\ []) when is_binary(version) do
    ip = Network.supervisor_ip()
    token = Keyword.get_lazy(opts, :token, &Token.get/0)
    tz = Keyword.get(opts, :tz, @default_tz)

    %{
      "Image" => image(version),
      "Hostname" => @default_name,
      "Env" => env(ip, token, tz),
      "HostConfig" => host_config(ip)
    }
  end

  defp env(ip, token, tz) do
    [
      "SUPERVISOR=#{ip}",
      "HASSIO=#{ip}",
      "SUPERVISOR_TOKEN=#{token}",
      "HASSIO_TOKEN=#{token}",
      "TZ=#{tz}"
    ]
  end

  defp host_config(ip) do
    %{
      "NetworkMode" => "host",
      "Privileged" => true,
      "OomScoreAdj" => -300,
      "RestartPolicy" => %{"Name" => "unless-stopped"},
      "ExtraHosts" => ["supervisor:#{ip}"],
      "Tmpfs" => %{"/tmp" => ""},
      "Mounts" => mounts()
    }
  end

  defp mounts do
    [
      # ro-NON-recursive: recursively read-only would also lock down
      # anything bind-mounted *under* /dev (e.g. bluetooth device nodes
      # attached after container start) — load-bearing for bluetooth.
      %{
        "Type" => "bind",
        "Source" => "/dev",
        "Target" => "/dev",
        "ReadOnly" => true,
        "BindOptions" => %{"ReadOnlyNonRecursive" => true}
      },
      %{"Type" => "bind", "Source" => "/run/dbus", "Target" => "/run/dbus", "ReadOnly" => true},
      %{"Type" => "bind", "Source" => "/run/udev", "Target" => "/run/udev", "ReadOnly" => true},
      %{"Type" => "volume", "Source" => "vagus-core-config", "Target" => "/config"}
    ]
  end
end
