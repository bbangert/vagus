defmodule Vagus.Addon.Backend.Spec do
  @moduledoc """
  Runtime-neutral description of an add-on instance — the interface between the
  add-on manager (`Vagus.Addon`, which populates it from the add-on config +
  the pinned run params, §A1.4) and a `Vagus.Addon.Backend` (which translates
  it to the concrete runtime, e.g. Docker JSON in `Backend.Container`).

  Only add-on-specific / config-derived fields live here. Cross-cutting
  invariants the real Supervisor always applies — `Privileged: false`,
  `SecurityOpt: seccomp=unconfined`, `Labels: supervisor_managed`,
  `OomScoreAdj: 200`, no restart policy — are owned by the backend, not carried
  per-spec (see `Backend.Container`).
  """

  @type network :: :hassio | :host

  # `:system` marks a source dir owned by the host system (e.g. /run/dbus,
  # created by Vagus.Bluetooth), not by the add-on manager: the manager must
  # never create it, so a missing source fails the add-on start loudly
  # instead of silently binding an empty directory.
  @type mount :: %{
          required(:source) => String.t(),
          required(:target) => String.t(),
          optional(:read_only) => boolean(),
          optional(:propagation) => String.t() | nil,
          optional(:system) => boolean()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          # nil for `backend: :native` add-ons, which run in-VM and have no
          # image (`Manager.image_ref/2` returns nil for them).
          image: String.t() | nil,
          hostname: String.t() | nil,
          cmd: [String.t()] | nil,
          env: %{optional(String.t()) => String.t()} | [String.t()],
          network: network(),
          network_name: String.t(),
          extra_hosts: %{optional(String.t()) => String.t()},
          dns: [String.t()],
          dns_search: [String.t()],
          dns_options: [String.t()],
          init: boolean(),
          open_stdin: boolean(),
          cap_add: [String.t()],
          apparmor: String.t() | nil,
          tmpfs: %{optional(String.t()) => String.t()},
          mounts: [mount()],
          device_cgroup_rules: [String.t()],
          ports: %{optional(String.t()) => String.t() | non_neg_integer() | nil},
          pid_mode: String.t() | nil,
          uts_mode: String.t() | nil,
          labels: %{optional(String.t()) => String.t()},
          platform: String.t() | nil
        }

  @enforce_keys [:name, :image]
  defstruct name: nil,
            image: nil,
            hostname: nil,
            cmd: nil,
            env: %{},
            network: :hassio,
            network_name: "hassio",
            extra_hosts: %{},
            dns: [],
            dns_search: [],
            dns_options: [],
            init: false,
            open_stdin: false,
            cap_add: [],
            apparmor: nil,
            tmpfs: %{},
            mounts: [],
            device_cgroup_rules: [],
            ports: %{},
            pid_mode: nil,
            uts_mode: nil,
            labels: %{},
            platform: nil
end
