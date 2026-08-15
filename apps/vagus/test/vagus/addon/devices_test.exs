defmodule Vagus.Addon.DevicesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Addon.{Config, Devices}

  defp config(raw) do
    {:ok, c} =
      Config.parse(
        Map.merge(
          %{
            "name" => "Device probe",
            "version" => "1.0.0",
            "slug" => "device_probe",
            "description" => "device rules",
            "arch" => ["amd64"],
            "image" => "example/{arch}-addon-probe"
          },
          raw
        )
      )

    c
  end

  describe "cgroup_rules/2 — device nodes" do
    test "a character device resolves to its major:minor with full rwm" do
      # /dev/null and /dev/zero are 1:3 and 1:5 on every Linux, container
      # included — the only device nodes safe to hard-code in a test.
      assert Devices.cgroup_rules(config(%{"devices" => ["/dev/null"]}), true) == ["c 1:3 rwm"]
      assert Devices.cgroup_rules(config(%{"devices" => ["/dev/zero"]}), true) == ["c 1:5 rwm"]
    end

    test "several devices resolve in declaration order" do
      cfg = config(%{"devices" => ["/dev/zero", "/dev/null"]})
      assert Devices.cgroup_rules(cfg, true) == ["c 1:5 rwm", "c 1:3 rwm"]
    end

    test "no devices declared → no rules and no filesystem access" do
      assert Devices.cgroup_rules(config(%{}), true) == []
      assert Devices.cgroup_rules(config(%{}), false) == []
    end
  end

  describe "cgroup_rules/2 — skips" do
    test "a device that does not exist is skipped with a warning, not an error" do
      cfg = config(%{"devices" => ["/dev/does-not-exist", "/dev/null"]})

      log = capture_log(fn -> assert Devices.cgroup_rules(cfg, true) == ["c 1:3 rwm"] end)

      assert log =~ "/dev/does-not-exist"
      assert log =~ "no such node"
    end

    test "a regular file emits no rule — this is the security boundary" do
      # The point isn't tidiness: only char/block S_IFMT bits emit a rule, so a
      # config naming a sensitive regular file cannot express a grant at all.
      path = Path.join(System.tmp_dir!(), "vagus-devices-#{System.unique_integer([:positive])}")
      File.write!(path, "not a device")
      on_exit(fn -> File.rm(path) end)

      log =
        capture_log(fn ->
          assert Devices.cgroup_rules(config(%{"devices" => [path]}), true) == []
        end)

      assert log =~ "not a character or block device"
    end

    test "a directory emits no rule" do
      log =
        capture_log(fn ->
          assert Devices.cgroup_rules(config(%{"devices" => ["/dev"]}), true) == []
        end)

      assert log =~ "not a character or block device"
    end
  end

  describe "cgroup_rules/2 — full_access gating" do
    test "full_access while protected grants nothing" do
      cfg = config(%{"full_access" => true})
      assert Devices.cgroup_rules(cfg, true) == []
    end

    test "full_access with protection off grants the blanket pair, before any device rule" do
      cfg = config(%{"full_access" => true, "devices" => ["/dev/null"]})

      assert Devices.cgroup_rules(cfg, false) == ["b *:* rwm", "c *:* rwm", "c 1:3 rwm"]
    end

    test "protection off without full_access grants no blanket" do
      cfg = config(%{"devices" => ["/dev/null"]})
      assert Devices.cgroup_rules(cfg, false) == ["c 1:3 rwm"]
    end

    test "a non-boolean protection value is refused rather than guessed at" do
      # The guard exists because `manager.ex`'s `not protected` raises on the
      # same input: without it the two would disagree about what a decoded
      # JSON `"false"` means, and one of those answers unlocks the blanket.
      cfg = config(%{"full_access" => true})

      # Decoded rather than literal: this is the shape the value really arrives
      # in (PR 2's `POST /addons/{slug}/security` body), and a literal `nil`
      # here is a compile-time type error rather than a runtime test.
      for body <- [~s({"protected": null}), ~s({"protected": "false"})] do
        posted = Jason.decode!(body)["protected"]
        assert_raise FunctionClauseError, fn -> Devices.cgroup_rules(cfg, posted) end
      end
    end
  end

  describe "system-disk refusal (upstream's allowed_for_access)" do
    test "a char device never consults the disk policy" do
      # Block-only, same as upstream — and the lazy resolve means a char-only
      # add-on never reads the mount table at all.
      assert Devices.cgroup_rules(config(%{"devices" => ["/dev/null"]}), true) == ["c 1:3 rwm"]
    end

    @tag :block_device
    test "a block device that backs system storage is refused at :error" do
      case first_block_device() do
        nil ->
          flunk("no block device found; run with --exclude block_device")

        path ->
          # The policy is injected, so this pins the refusal itself rather than
          # whatever storage layout the host happens to have. An earlier
          # version asserted only a refused/granted *pairing* and so passed
          # down either branch, pinning nothing.
          {major, minor} = devnum(path)
          cfg = config(%{"devices" => [path]})

          log =
            capture_log(fn ->
              assert Devices.cgroup_rules(cfg, true, system_disk: MapSet.new([{major, minor}])) ==
                       []
            end)

          assert log =~ "tried to access blocked device"
      end
    end

    @tag :block_device
    test "the same block device is granted when it is not system storage" do
      case first_block_device() do
        nil ->
          flunk("no block device found; run with --exclude block_device")

        path ->
          {major, minor} = devnum(path)
          cfg = config(%{"devices" => [path]})

          assert Devices.cgroup_rules(cfg, true, system_disk: MapSet.new()) ==
                   ["b #{major}:#{minor} rwm"]
      end
    end

    test "an :unknown policy refuses every block device, and no char device" do
      # `SystemDisk.devnums/1` collapses to `:unknown` on any unresolved step;
      # this is the consuming half of that contract.
      char = config(%{"devices" => ["/dev/null"]})

      assert Devices.cgroup_rules(char, true, system_disk: :unknown) == ["c 1:3 rwm"]
    end
  end

  describe "symlinks" do
    test "a symlink resolves to its target's device number" do
      # `File.stat/1` over `lstat` is deliberate — HA 2026.x accepts stable
      # `/dev/serial/by-id/…` symlinks. The rule must describe the node the
      # link points at, not the link.
      link = Path.join(System.tmp_dir!(), "vagus-devlink-#{System.unique_integer([:positive])}")
      File.ln_s!("/dev/zero", link)
      on_exit(fn -> File.rm(link) end)

      assert Devices.cgroup_rules(config(%{"devices" => [link]}), true) == ["c 1:5 rwm"]
    end

    test "a symlink to a non-device still emits nothing" do
      # The security boundary has to survive indirection: the declared string
      # says nothing about what gets granted, only the resolved node does.
      link = Path.join(System.tmp_dir!(), "vagus-etclink-#{System.unique_integer([:positive])}")
      File.ln_s!("/etc/hosts", link)
      on_exit(fn -> File.rm(link) end)

      log =
        capture_log(fn ->
          assert Devices.cgroup_rules(config(%{"devices" => [link]}), true) == []
        end)

      assert log =~ "not a character or block device"
    end
  end

  describe "block devices" do
    @describetag :block_device

    # Settles the Erlang doc's claim that `minor_device` is "only valid for
    # character devices on Unix". It is not — it is `st_rdev` for every node
    # type. Proven against a `mknod`'d `b 8:0`: `minor_device` read 2048
    # (0x800) → 8:0, `mode &&& 0o170000` == 0o60000. Excluded by default
    # because the dev container has no block node; run it on a board, or with
    # `sudo mknod /dev/x b 8 0`, via `mix test --include block_device`.
    test "a block device classifies as `b` and decodes against sysfs" do
      case first_block_device() do
        nil ->
          flunk("no block device found; run with --exclude block_device")

        path ->
          # Empty policy injected on purpose: this test is about char/block
          # classification and the devnum decode, and without the injection it
          # fails on any board whose first block node IS system storage — the
          # rule list would correctly be empty.
          assert ["b " <> majmin] =
                   Devices.cgroup_rules(config(%{"devices" => [path]}), true,
                     system_disk: MapSet.new()
                   )

          assert [pair, "rwm"] = String.split(majmin, " ")

          # sysfs is the kernel's own statement of the pair, derived from a
          # completely different path than stat(2) — which is what makes it a
          # check rather than a restatement.
          assert File.exists?("/sys/dev/block/#{pair}")
      end
    end
  end

  # Independent of the module under test: reads the pair from sysfs rather than
  # from `cgroup_rules/2`'s own output, so injecting it cannot make the
  # assertion circular.
  defp devnum(path) do
    name = Path.basename(path)

    case File.read("/sys/class/block/#{name}/dev") do
      {:ok, contents} ->
        [major, minor] = contents |> String.trim() |> String.split(":")
        {String.to_integer(major), String.to_integer(minor)}

      {:error, _reason} ->
        # A node with no sysfs entry (e.g. a hand-mknod'd one) — fall back to
        # the kernel's rdev, which is the same number by a different route.
        {:ok, %File.Stat{minor_device: rdev}} = File.stat(path)
        {Bitwise.band(Bitwise.bsr(rdev, 8), 0xFFF), Bitwise.band(rdev, 0xFF)}
    end
  end

  defp first_block_device do
    Enum.find(Path.wildcard("/dev/*"), fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o170000) == 0o60000
        _ -> false
      end
    end)
  end
end
