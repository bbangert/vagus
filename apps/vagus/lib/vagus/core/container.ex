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

  ## The Supervisor socket (`/run/supervisor`)

  `SUPERVISOR_CORE_API_SOCKET=/run/supervisor/core.sock` makes Core open a
  unix socket at that path *inside* its container
  (`homeassistant/components/http`), and the `/run/supervisor` bind-mount is
  what puts that socket in Vagus's own mount namespace so Vagus can talk to
  Core over it — the channel real HAOS uses (implicit Supervisor-user auth,
  no bearer token).

  The directory lives on tmpfs and is therefore gone after every boot, which
  is correct: the socket is per-boot state. `Vagus.Engine.Manager` recreates
  it before it starts the balena-engine daemon — the daemon revives Core's
  `unless-stopped` container immediately, and a bind mount whose source is
  missing fails the container start outright.

  ## Deliberate v1 omissions vs. upstream `docker/homeassistant.py`

  * **`/etc/machine-id` bind** — Nerves' `/etc` is read-only firmware, there
    is no writable machine-id file to bind in.
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
    port 80 is implicit on this address, and an explicit suffix was
    device-proven to break Core during the bluetooth work. Since the
    Supervisor-API listener vacated port 80 for Core (`Vagus.API.Listener`
    binds the anchor on `:api_port`), `172.30.32.2:80` is a destination
    rewrite rather than a socket (`Vagus.Network.Nat`) — which is exactly
    what keeps the bare form here correct, and why it must stay bare.
  """

  alias Vagus.API.Token
  alias Vagus.Network

  @image_repo "ghcr.io/home-assistant/home-assistant"
  @default_name "homeassistant"
  @default_tz "UTC"

  @socket_dir "/run/supervisor"
  @socket_path @socket_dir <> "/core.sock"

  @spec_fingerprint_label "io.vagus.spec-fingerprint"
  @spec_fingerprint_length 32

  @doc "The fixed Core container name (`homeassistant`) — upstream parity."
  @spec name() :: String.t()
  def name do
    Application.get_env(:vagus, :core_container) || @default_name
  end

  @doc "The named docker volume holding Core's /config (see mounts/0)."
  @spec config_volume() :: String.t()
  def config_volume, do: "vagus-core-config"

  @doc """
  The bind-mounted directory holding Core's Supervisor socket
  (`#{@socket_dir}`) — same path on both sides of the mount. Created per
  boot by `Vagus.Engine.Manager` (see the moduledoc).
  """
  @spec socket_dir() :: String.t()
  def socket_dir, do: @socket_dir

  @doc """
  The Supervisor socket Core opens (`#{@socket_path}`), i.e. the
  `SUPERVISOR_CORE_API_SOCKET` value — a host path once `socket_dir/0` is
  bind-mounted in.
  """
  @spec socket_path() :: String.t()
  def socket_path, do: @socket_path

  @doc """
  The container label carrying `spec_fingerprint/1` (`#{@spec_fingerprint_label}`).
  """
  @spec spec_fingerprint_label() :: String.t()
  def spec_fingerprint_label, do: @spec_fingerprint_label

  @doc """
  Host path of Core's /config — the `vagus-core-config` named volume's
  on-disk location, the docker "local" volume driver's fixed
  `<data_root>/volumes/<name>/_data` layout (same convention
  `Vagus.Backend.Host.DiskBreakdown` resolves for the disk-usage
  breakdown's `homeassistant` node). `opts[:homeassistant_path]`
  overrides the path outright — the real
  `<Vagus.Engine.Manager.data_root()>/volumes/...` tree only exists on
  target, so host tests point this at a tmp dir.
  """
  @spec config_path(keyword()) :: String.t()
  def config_path(opts \\ []) do
    Keyword.get_lazy(opts, :homeassistant_path, fn ->
      Path.join([Vagus.Engine.Manager.data_root(), "volumes", config_volume(), "_data"])
    end)
  end

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

    spec = %{
      "Image" => image(version),
      "Hostname" => @default_name,
      "Env" => env(ip, token, tz),
      "HostConfig" => host_config(ip)
    }

    Map.put(spec, "Labels", %{@spec_fingerprint_label => spec_fingerprint(spec)})
  end

  @doc """
  A deterministic digest of everything in a `create_config/2` map that a
  running container would have to be recreated to pick up — the whole spec
  (image, env, host config, mounts) except the `"Labels"` key the digest
  itself is stamped into.

  `Vagus.Core.Lifecycle` stamps this on every container it creates and
  compares it against the existing container's label before reusing one, so
  a spec change here (a new mount, a new env var, a rotated token) triggers
  the same recreate an image/version mismatch does — a *missing* label (a
  container created before fingerprinting existed, or by hand) never matches
  and so always recreates.

  Pure: same spec in, same digest out. Nested maps are canonicalized to
  key-sorted pairs first so the digest can't depend on map iteration order.
  """
  @spec spec_fingerprint(map()) :: String.t()
  def spec_fingerprint(spec) when is_map(spec) do
    digest =
      spec
      |> Map.delete("Labels")
      |> canonical()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    binary_part(digest, 0, @spec_fingerprint_length)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [key, canonical(value)] end)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp env(ip, token, tz) do
    [
      "SUPERVISOR=#{ip}",
      "HASSIO=#{ip}",
      "SUPERVISOR_TOKEN=#{token}",
      "HASSIO_TOKEN=#{token}",
      "SUPERVISOR_CORE_API_SOCKET=#{@socket_path}",
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
      # Writable: Core creates its Supervisor socket inside this directory
      # (see the moduledoc's "The Supervisor socket" section).
      %{
        "Type" => "bind",
        "Source" => @socket_dir,
        "Target" => @socket_dir,
        "ReadOnly" => false
      },
      %{"Type" => "volume", "Source" => "vagus-core-config", "Target" => "/config"}
    ]
  end
end
