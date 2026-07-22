defmodule Vagus.ImprovTest do
  use ExUnit.Case, async: true

  describe "classify/3" do
    test "disconnected only when nothing has connectivity" do
      assert Vagus.Improv.classify(:disconnected, :disconnected, :disconnected) == :disconnected
      assert Vagus.Improv.classify(nil, nil, :disconnected) == :disconnected
      assert Vagus.Improv.classify(nil, nil, nil) == :disconnected
    end

    test "wifi wins the label when wlan has connectivity" do
      assert Vagus.Improv.classify(:disconnected, :lan, :lan) == :wifi
      assert Vagus.Improv.classify(:internet, :internet, :internet) == :wifi
    end

    test "ethernet when only eth is up" do
      assert Vagus.Improv.classify(:lan, :disconnected, :lan) == :ethernet
      assert Vagus.Improv.classify(:internet, nil, :internet) == :ethernet
    end

    test "aggregate catches unnamed interfaces (usb0, ...)" do
      assert Vagus.Improv.classify(:disconnected, :disconnected, :internet) == :other
    end

    test ":lan counts as connected — a LAN-only boot must NOT arm improv" do
      # Wrong-password wifi flaps blip :lan; a plugged-but-no-internet
      # ethernet is also :lan. Neither is "offline".
      refute Vagus.Improv.classify(:lan, nil, :lan) == :disconnected
    end
  end

  describe "network_type/0 force-offline override" do
    test "app env forces :disconnected" do
      Application.put_env(:vagus, :improv_force_offline, true)

      try do
        assert Vagus.Improv.network_type() == :disconnected
      after
        Application.delete_env(:vagus, :improv_force_offline)
      end
    end
  end

  describe "supervisor_opts/0" do
    test "pins the arm gate, branding, and derived capabilities inputs" do
      opts = Vagus.Improv.supervisor_opts()

      # The arm gate MUST be set: improv treats a nil network_type as
      # "always online" (fail-closed), which would make provisioning
      # unreachable on device.
      assert opts[:network_type] == (&Vagus.Improv.network_type/0)
      assert opts[:name_prefix] == "Vagus"
      # Both optional-command callbacks present -> capabilities byte 0x07.
      assert is_function(opts[:identify_fun], 0)

      info = opts[:device_info]
      assert info[:firmware_name] == "Vagus"
      assert is_binary(info[:firmware_version])
      # device_name mirrors the advertised name (prefix + MAC/hostname tail).
      assert String.starts_with?(info[:device_name], "Vagus ")
    end
  end

  describe "supervisor_child/0" do
    test "is an Improv.Supervisor child tuple carrying the opts" do
      assert {Improv.Supervisor, opts} = Vagus.Improv.supervisor_child()
      assert opts[:name_prefix] == "Vagus"
    end
  end
end
