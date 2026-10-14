defmodule Vagus.Runtime.Engine.ContainerSpec do
  @moduledoc """
  The engine-neutral container create spec.

  A `nil` field is left to the engine's default and omitted from the render;
  `[]`, `%{}` and `false` are stated values and are rendered. `env` and
  `extra_hosts` render in list order, so a caller that needs a stable order
  sorts them itself. `ports` and `network_aliases` only apply to a bridged
  container and render only when non-empty.

  `secret_env` names the `env` entries whose values are secrets, so an
  engine driven through argv can pass them some other way.
  """

  @type mount :: %{
          required(:type) => :bind | :volume,
          required(:source) => String.t(),
          required(:target) => String.t(),
          optional(:read_only) => boolean() | nil,
          optional(:propagation) => String.t() | nil,
          optional(:read_only_non_recursive) => boolean() | nil
        }

  @type network :: :host | {:bridge, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          image: String.t(),
          cmd: [String.t()] | nil,
          env: [{String.t(), String.t()}] | nil,
          secret_env: [String.t()],
          hostname: String.t() | nil,
          domainname: String.t() | nil,
          open_stdin: boolean() | nil,
          labels: %{optional(String.t()) => String.t()} | nil,
          network: network(),
          network_aliases: [String.t()] | nil,
          dns: [String.t()] | nil,
          dns_search: [String.t()] | nil,
          dns_options: [String.t()] | nil,
          extra_hosts: [{String.t(), String.t()}] | nil,
          mounts: [mount()] | nil,
          tmpfs: %{optional(String.t()) => String.t()} | nil,
          device_cgroup_rules: [String.t()] | nil,
          cap_add: [String.t()] | nil,
          privileged: boolean() | nil,
          init: boolean() | nil,
          oom_score_adj: integer() | nil,
          security_opt: [String.t()] | nil,
          restart: nil | :no | :unless_stopped,
          ports: %{optional(String.t()) => non_neg_integer() | String.t() | nil} | nil,
          pid_mode: String.t() | nil,
          uts_mode: String.t() | nil
        }

  @enforce_keys [:name, :image, :network]
  defstruct name: nil,
            image: nil,
            cmd: nil,
            env: nil,
            secret_env: [],
            hostname: nil,
            domainname: nil,
            open_stdin: nil,
            labels: nil,
            network: nil,
            network_aliases: nil,
            dns: nil,
            dns_search: nil,
            dns_options: nil,
            extra_hosts: nil,
            mounts: nil,
            tmpfs: nil,
            device_cgroup_rules: nil,
            cap_add: nil,
            privileged: nil,
            init: nil,
            oom_score_adj: nil,
            security_opt: nil,
            restart: nil,
            ports: nil,
            pid_mode: nil,
            uts_mode: nil
end
