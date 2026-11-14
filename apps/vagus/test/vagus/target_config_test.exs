defmodule Vagus.TargetConfigTest do
  use ExUnit.Case, async: true

  @config_dir Path.expand("../../../../config", __DIR__)

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
  end
end
