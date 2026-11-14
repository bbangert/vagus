defmodule Vagus.Runtime.ResolvConfTest do
  use ExUnit.Case, async: true

  alias Vagus.Runtime.ResolvConf

  describe "build/1" do
    test "renders one nameserver line per plain IP tuple" do
      assert ResolvConf.build([{1, 1, 1, 1}, {8, 8, 8, 8}]) ==
               "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
    end

    test "renders VintageNet's [\"name_servers\"] map shape (address key)" do
      servers = [
        %{address: {192, 168, 1, 1}, from: ["eth0"]},
        %{address: {1, 1, 1, 1}, from: [:global]}
      ]

      assert ResolvConf.build(servers) ==
               "nameserver 192.168.1.1\nnameserver 1.1.1.1\n"
    end

    test "falls back to the static resolvers when given an empty list" do
      assert ResolvConf.build([]) == ResolvConf.build(ResolvConf.fallback_servers())
      assert ResolvConf.build([]) == "nameserver 1.1.1.1\nnameserver 8.8.8.8\n"
    end

    test "supports IPv6 addresses" do
      assert ResolvConf.build([{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]) ==
               "nameserver 2606:4700:4700::1111\n"
    end
  end

  describe "the DNS stub" do
    @tag :tmp_dir
    test "holds the spec's settings alone, and is written once", %{tmp_dir: dir} do
      {:ok, path} = ResolvConf.write_stub(dir, ["172.30.32.3"], ["local.hass.io"], ["timeout:10"])

      assert path == ResolvConf.stub_path(dir, ["172.30.32.3"], ["local.hass.io"], ["timeout:10"])

      assert File.read!(path) ==
               "nameserver 172.30.32.3\nsearch local.hass.io\noptions timeout:10\n"

      File.write!(path, "kept")

      assert {:ok, ^path} =
               ResolvConf.write_stub(dir, ["172.30.32.3"], ["local.hass.io"], ["timeout:10"])

      assert File.read!(path) == "kept"
      assert File.ls!(dir) == [Path.basename(path)]
    end

    @tag :tmp_dir
    test "other settings are another file, and absent ones no line", %{tmp_dir: dir} do
      {:ok, a} = ResolvConf.write_stub(dir, ["172.30.32.3"], nil, [])
      {:ok, b} = ResolvConf.write_stub(dir, ["172.30.32.3"], ["local.hass.io"], nil)

      refute a == b
      assert File.read!(a) == "nameserver 172.30.32.3\n"
      assert File.read!(b) == "nameserver 172.30.32.3\nsearch local.hass.io\n"
    end

    # Only discriminates under a restrictive umask, which is why CI runs the suite under 077.
    @tag :tmp_dir
    test "a fresh stub is 0644", %{tmp_dir: dir} do
      {:ok, path} = ResolvConf.write_stub(dir, ["172.30.32.3"], nil, nil)

      assert mode(path) == 0o644
    end

    @tag :tmp_dir
    test "a stub written 0600 is healed in place", %{tmp_dir: dir} do
      {:ok, path} = ResolvConf.write_stub(dir, ["172.30.32.3"], nil, nil)
      File.chmod!(path, 0o600)
      inode = File.stat!(path).inode

      assert {:ok, ^path} = ResolvConf.write_stub(dir, ["172.30.32.3"], nil, nil)

      assert mode(path) == 0o644
      assert File.stat!(path).inode == inode
    end

    test "a directory it cannot make is the error, not a crash" do
      assert {:error, _} = ResolvConf.write_stub("/proc/no-such/dir", ["172.30.32.3"], nil, nil)
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "path/0 is /run/resolv.conf" do
    assert ResolvConf.path() == "/run/resolv.conf"
  end
end
