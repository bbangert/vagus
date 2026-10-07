defmodule Vagus.App.Facts do
  @moduledoc """
  What admission and the container config need to know about the machine
  they run on, as data: the pure functions of `Vagus.App.Spec.Schema` and
  `Vagus.App.Container.Config` take one of these and read nothing else.

  `arch` is the architecture the device reports and apps are offered for;
  `image_arch` is the one images are pulled for. They differ only where
  the engine runs on another machine than the one being emulated.

  `core_version` is `nil` when unknown, which no app is refused over.
  `dsp_root` is `nil` on a board without a DSP.
  """

  alias Vagus.Addon.Ports
  alias Vagus.API.StaticData
  alias Vagus.Network

  @enforce_keys [:arch, :image_arch, :machine, :data_root, :network_name, :supervisor_ip, :dns_ip]
  defstruct [
    :arch,
    :image_arch,
    :machine,
    :core_version,
    :data_root,
    :network_name,
    :supervisor_ip,
    :dns_ip,
    :dsp_root,
    timezone: "UTC",
    reserved_host_ports: [],
    native_apps: []
  ]

  @type t :: %__MODULE__{
          arch: String.t(),
          image_arch: String.t(),
          machine: String.t(),
          core_version: String.t() | nil,
          data_root: Path.t(),
          network_name: String.t(),
          supervisor_ip: String.t(),
          dns_ip: String.t(),
          dsp_root: Path.t() | nil,
          timezone: String.t(),
          reserved_host_ports: [non_neg_integer()],
          native_apps: [String.t()]
        }

  @doc """
  The facts of this machine, read from the application's configuration.
  `overrides` replace any of them; `core_version` is never read here, since
  whoever knows it holds a resource and not a setting.
  """
  @spec read(keyword()) :: t()
  def read(overrides \\ []) do
    struct!(
      %__MODULE__{
        arch: StaticData.arch(),
        image_arch: image_arch(),
        machine: StaticData.machine(),
        data_root: Application.get_env(:vagus, :addon_data_root, "/data"),
        network_name: Network.name(),
        supervisor_ip: Network.supervisor_ip(),
        dns_ip: Network.dns_ip(),
        dsp_root: Application.get_env(:vagus, :dsp_root),
        reserved_host_ports: Ports.reserved_host_ports(),
        native_apps: Application.get_env(:vagus, :native_addon_slugs, ["core_mqtt"])
      },
      overrides
    )
  end

  defp image_arch do
    arch = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.contains?(arch, "aarch64") -> "aarch64"
      String.contains?(arch, "x86_64") -> "amd64"
      String.contains?(arch, "arm") -> "armv7"
      true -> "amd64"
    end
  end
end
