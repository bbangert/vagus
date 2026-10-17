defmodule Vagus.Core.Container do
  @moduledoc """
  Pure builder for the HA Core container's
  `Vagus.Runtime.Engine.ContainerSpec` — the device-proven
  real-Supervisor-parity run spec settled during the bluetooth work (see
  `.claude/plans/vagus-core-lifecycle/research/supervisor-semantics.md`,
  mirroring upstream `supervisor/docker/homeassistant.py`).

  This is Core's OWN spec builder, deliberately separate from
  `Vagus.Addon.Backend.Container.to_container_spec/1`: the add-on builder
  hard-stamps `privileged: false` / `oom_score_adj: 200` as a cross-cutting
  add-on security invariant, and Core's `privileged: true` spec must not
  reuse (and thereby weaken) that seam.

  `to_container_spec/2` has no side effects beyond its `Token.get/0` and
  `Vagus.Runtime.Migration.core_config_path/1` defaults — no processes, no
  engine calls. `Vagus.Core.Lifecycle` is what actually creates/starts/stops
  containers from this spec.

  ## The Supervisor socket (`/run/supervisor`)

  `SUPERVISOR_CORE_API_SOCKET=/run/supervisor/core.sock` makes Core open a
  unix socket at that path *inside* its container
  (`homeassistant/components/http`), and the `/run/supervisor` bind-mount is
  what puts that socket in Vagus's own mount namespace so Vagus can talk to
  Core over it — the channel real HAOS uses (implicit Supervisor-user auth,
  no bearer token).

  The directory lives on tmpfs and is therefore gone after every boot, which
  is correct: the socket is per-boot state. `Vagus.Runtime.Host` recreates
  it in its preparation, before Core is created: a bind mount whose source
  is missing fails the container start outright.

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

  * `restart: :unless_stopped` — upstream owns Core restarts itself
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
  alias Vagus.Runtime.Engine.ContainerSpec
  alias Vagus.Runtime.Migration

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

  @doc """
  The bind-mounted directory holding Core's Supervisor socket
  (`#{@socket_dir}`) — same path on both sides of the mount. Created per
  boot by `Vagus.Runtime.Host` (see the moduledoc).
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
  Host path of Core's /config, which Core binds: a named volume would start
  empty in podman's own store. `Vagus.Runtime.Migration.core_config_path/1`
  picks it, the legacy directory until it has been moved out of balena's
  tree. `opts[:homeassistant_path]` overrides it outright, since host tests
  have neither tree.
  """
  @spec config_path(keyword()) :: String.t()
  def config_path(opts \\ []),
    do: Keyword.get_lazy(opts, :homeassistant_path, fn -> Migration.core_config_path() end)

  @doc "The Core image reference for `version`, e.g. `ghcr.io/home-assistant/home-assistant:2026.7.0`."
  @spec image(String.t()) :: String.t()
  def image(version) when is_binary(version), do: @image_repo <> ":" <> version

  @doc "Whether `ref` is a Core image at some version."
  @spec image?(String.t()) :: boolean()
  def image?(ref) when is_binary(ref), do: String.starts_with?(ref, @image_repo <> ":")

  @doc """
  The spec for HA Core at `version`, stamped with its `spec_fingerprint/1`
  label.

  Options:

    * `:token` - the Supervisor/HASSIO bearer token Core authenticates
      back to Vagus with. Defaults to `Vagus.API.Token.get/0`; injectable
      so tests never touch the real persisted/on-disk token.
    * `:tz` - the `TZ` env value. Defaults to `"UTC"`.
    * `:homeassistant_path` - the /config bind source (see `config_path/1`).
  """
  @spec to_container_spec(String.t(), keyword()) :: ContainerSpec.t()
  def to_container_spec(version, opts \\ []) when is_binary(version) do
    ip = Network.supervisor_ip()
    token = Keyword.get_lazy(opts, :token, &Token.get/0)
    tz = Keyword.get(opts, :tz, @default_tz)

    spec = %ContainerSpec{
      name: name(),
      image: image(version),
      hostname: @default_name,
      env: env(ip, token, tz),
      secret_env: ["SUPERVISOR_TOKEN", "HASSIO_TOKEN"],
      network: :host,
      privileged: true,
      oom_score_adj: -300,
      restart: :unless_stopped,
      extra_hosts: [{"supervisor", ip}],
      tmpfs: %{"/tmp" => ""},
      mounts: mounts(opts)
    }

    %{spec | labels: %{@spec_fingerprint_label => spec_fingerprint(spec)}}
  end

  @doc """
  A deterministic digest of everything in `spec` that a running container
  would have to be recreated to pick up — all of it but `labels` (the digest
  itself is stamped there), `name` and `secret_env`.

  `Vagus.Core.Lifecycle` stamps this on every container it creates and
  compares it against the existing container's label before reusing one, so
  a spec change here (a new mount, a new env var, a rotated token) triggers
  the same recreate an image/version mismatch does — a *missing* label (a
  container created before fingerprinting existed, or by hand) never matches
  and so always recreates.
  """
  @spec spec_fingerprint(ContainerSpec.t()) :: String.t()
  def spec_fingerprint(%ContainerSpec{} = spec) do
    digest =
      spec
      |> fingerprint_body()
      |> canonical()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    binary_part(digest, 0, @spec_fingerprint_length)
  end

  # The fields `fingerprint_body/1` renders in the Docker shape.
  @shaped [:image, :hostname, :env, :network, :privileged, :oom_score_adj] ++
            [:restart, :extra_hosts, :mounts, :tmpfs]
  @unhashed [:name, :secret_env, :labels]

  # Every Core container carries a label hashed over this exact shape, the
  # Docker Engine-API create body the first fingerprints were computed from:
  # a different shape for the same spec would recreate Core on every board.
  # A field the shape lacks is hashed under its own name once set, so it
  # still changes the digest without moving any digest taken while unset.
  defp fingerprint_body(%ContainerSpec{} = spec) do
    host_config =
      drop_nil(%{
        "NetworkMode" => network_mode(spec.network),
        "Privileged" => spec.privileged,
        "OomScoreAdj" => spec.oom_score_adj,
        "RestartPolicy" => restart_policy(spec.restart),
        "ExtraHosts" => spec.extra_hosts && Enum.map(spec.extra_hosts, &pair(&1, ":")),
        "Mounts" => spec.mounts && Enum.map(spec.mounts, &fingerprint_mount/1),
        "Tmpfs" => spec.tmpfs
      })

    unshaped =
      for {field, value} <- Map.from_struct(spec),
          field not in @shaped and field not in @unhashed and value != nil,
          into: %{},
          do: {Atom.to_string(field), value}

    %{
      "Image" => spec.image,
      "Hostname" => spec.hostname,
      "Env" => spec.env && Enum.map(spec.env, &pair(&1, "=")),
      "HostConfig" => host_config
    }
    |> drop_nil()
    |> Map.merge(unshaped)
  end

  defp pair({key, value}, separator), do: "#{key}#{separator}#{value}"

  defp network_mode(:host), do: "host"
  defp network_mode({:bridge, name}), do: name

  defp restart_policy(nil), do: nil
  defp restart_policy(:no), do: %{"Name" => ""}
  defp restart_policy(:unless_stopped), do: %{"Name" => "unless-stopped"}

  defp fingerprint_mount(%{type: :bind} = m) do
    bind_options =
      drop_nil(%{
        "Propagation" => Map.get(m, :propagation),
        "ReadOnlyNonRecursive" => if(Map.get(m, :read_only_non_recursive), do: true)
      })

    drop_nil(%{
      "Type" => "bind",
      "Source" => m.source,
      "Target" => m.target,
      "ReadOnly" => Map.get(m, :read_only) || false,
      "BindOptions" => if(bind_options != %{}, do: bind_options)
    })
  end

  defp fingerprint_mount(m), do: Map.new(m, fn {key, value} -> {Atom.to_string(key), value} end)

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [key, canonical(value)] end)
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp env(ip, token, tz) do
    [
      {"SUPERVISOR", ip},
      {"HASSIO", ip},
      {"SUPERVISOR_TOKEN", token},
      {"HASSIO_TOKEN", token},
      {"SUPERVISOR_CORE_API_SOCKET", @socket_path},
      {"TZ", tz}
    ]
  end

  defp mounts(opts) do
    [
      # ro-NON-recursive: recursively read-only would also lock down
      # anything bind-mounted *under* /dev (e.g. bluetooth device nodes
      # attached after container start) — load-bearing for bluetooth.
      %{
        type: :bind,
        source: "/dev",
        target: "/dev",
        read_only: true,
        read_only_non_recursive: true
      },
      %{type: :bind, source: "/run/dbus", target: "/run/dbus", read_only: true},
      %{type: :bind, source: "/run/udev", target: "/run/udev", read_only: true},
      # Writable: Core creates its Supervisor socket inside this directory
      # (see the moduledoc's "The Supervisor socket" section).
      %{type: :bind, source: @socket_dir, target: @socket_dir, read_only: false},
      %{type: :bind, source: config_path(opts), target: "/config", read_only: false}
    ]
  end
end
