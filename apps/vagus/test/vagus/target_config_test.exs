defmodule Vagus.TargetConfigTest do
  use ExUnit.Case, async: true

  @config_dir Path.expand("../../../../config", __DIR__)

  # CI checks the system out beside the repo only in the lock-check job, so the
  # platform test reads it where present and is skipped elsewhere.
  @fwup_common Path.expand(
                 "../../../../../nerves_system_vagus/ha_green/base/fwup_include/fwup-common.conf",
                 __DIR__
               )

  describe "ha_green" do
    setup do
      {:ok, config: Config.Reader.read!(Path.join(@config_dir, "ha_green.exs"))}
    end

    test "reports the machine Supervisor knows as green", %{config: config} do
      assert config[:vagus][:machine] == "green"
    end

    test "is Ethernet only: no radio, no gadget interface", %{config: config} do
      assert [{"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}] =
               config[:vintage_net][:config]
    end

    test "has no DSP", %{config: config} do
      refute Keyword.has_key?(config[:vagus], :dsp_root)
    end

    # `/os/info`'s board is the firmware's platform. Core maps board `green` to
    # its homeassistant_green integration, which calls `/os/boards/green`, and
    # Vagus does not serve it.
    @tag skip: not File.exists?(@fwup_common) && "nerves_system_vagus is not checked out"
    test "the firmware platform, which is the /os/info board, is not green" do
      assert [_, platform] =
               Regex.run(~r/define!\(NERVES_FW_PLATFORM, "([^"]+)"\)/, File.read!(@fwup_common))

      refute platform == "green"
    end
  end
end
