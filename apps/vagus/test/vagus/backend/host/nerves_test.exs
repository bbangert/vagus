defmodule Vagus.Backend.Host.NervesTest do
  use ExUnit.Case, async: true

  alias Vagus.Backend.Host.Nerves

  setup do
    root = Path.join(System.tmp_dir!(), "vagus_nerves_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp write!(root, name, contents) do
    path = Path.join(root, name)
    File.write!(path, contents)
    path
  end

  describe "kernel/1" do
    test "reads and trims /proc/sys/kernel/osrelease-shaped content", ctx do
      path = write!(ctx.root, "osrelease", "7.1.4\n")

      assert Nerves.kernel(path) == "7.1.4"
    end

    test "missing file returns nil", ctx do
      assert Nerves.kernel(Path.join(ctx.root, "nope")) == nil
    end
  end

  describe "operating_system/1" do
    test "real Q6A os-release (no PRETTY_NAME) composes NAME + system name + version", ctx do
      path =
        write!(ctx.root, "os-release", """
        NAME=Nerves
        ID=nerves
        NERVES_SYSTEM_BR_VERSION=1.34.0
        NERVES_SYSTEM_NAME=dragon_q6a
        NERVES_SYSTEM_VERSION=0.2.0
        NERVES_BUILDROOT_VERSION=2026.05
        """)

      assert Nerves.operating_system(path) == "Nerves dragon_q6a 0.2.0"
    end

    test "PRETTY_NAME wins when present, quotes stripped", ctx do
      path =
        write!(ctx.root, "os-release", """
        NAME="Debian GNU/Linux"
        PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        ID=debian
        """)

      assert Nerves.operating_system(path) == "Debian GNU/Linux 12 (bookworm)"
    end

    test "missing file returns nil", ctx do
      assert Nerves.operating_system(Path.join(ctx.root, "nope")) == nil
    end

    test "empty file returns nil", ctx do
      path = write!(ctx.root, "os-release", "")

      assert Nerves.operating_system(path) == nil
    end

    test "no NAME and no PRETTY_NAME at all returns nil", ctx do
      path = write!(ctx.root, "os-release", "ID=mystery\nVERSION_ID=1\n")

      assert Nerves.operating_system(path) == nil
    end
  end
end
