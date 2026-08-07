defmodule Vagus.Core.PortMigrationTest do
  @moduledoc """
  `async: true` — every test injects both of the module's paths
  (`:port_migration_marker`, `:homeassistant_path`) into a per-test tmp
  tree, so nothing here reads app env, `/data`, or the engine's volume
  directory.

  The store fixture is the real shape Core 2026.8.0 writes
  (`homeassistant/components/http/config.py`'s `_HTTPStoreData` inside
  `helpers/storage.py`'s `{version, minor_version, key, data}` envelope,
  serialized 2-space-pretty the way `helpers/json.py` does with orjson's
  `OPT_INDENT_2`), not a minimal hand-made one — the whole point of the
  migration is that it touches exactly one field of it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Vagus.Core.PortMigration

  @store_relative_path ".storage/http"

  ## Fixtures

  defp unique, do: System.unique_integer([:positive])

  # Stands in for the `vagus-core-config` volume's host-side directory.
  defp tmp_volume do
    dir = Path.join(System.tmp_dir!(), "vagus_test_port_migration_#{unique()}")
    File.mkdir_p!(Path.join(dir, ".storage"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # Not created — the module is what creates it (and its parent).
  defp tmp_marker do
    path =
      Path.join([
        System.tmp_dir!(),
        "vagus_test_port_migration_marker_#{unique()}",
        "core_port_migration"
      ])

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
    path
  end

  # A regular file where the marker's parent directory must go, so `mkdir_p`
  # fails :enotdir regardless of uid.
  defp unwritable_marker do
    blocker = Path.join(System.tmp_dir!(), "vagus_test_port_migration_blocker_#{unique()}")
    File.write!(blocker, "")
    on_exit(fn -> File.rm_rf!(blocker) end)
    Path.join(blocker, "core_port_migration")
  end

  defp store_path(dir), do: Path.join(dir, @store_relative_path)

  defp store(data_overrides \\ %{}) do
    %{
      "version" => 2,
      "minor_version" => 2,
      "key" => "http",
      "data" =>
        Map.merge(
          %{
            "stable" => %{
              "server_port" => 8123,
              "cors_allowed_origins" => ["https://cast.home-assistant.io"],
              "ip_ban_enabled" => true,
              "login_attempts_threshold" => -1,
              "ssl_profile" => "modern",
              "use_x_frame_options" => true,
              "trusted_proxies" => ["172.30.32.0/23"],
              "created_at" => "2026-08-06T09:14:02.113512+00:00",
              "error" => nil,
              "error_message" => nil
            },
            "pending" => nil,
            "yaml_migration_done" => true
          },
          data_overrides
        )
    }
  end

  defp with_stable_port(port) do
    store(%{"stable" => Map.put(store()["data"]["stable"], "server_port", port)})
  end

  defp write_store!(dir, contents) when is_binary(contents) do
    File.write!(store_path(dir), contents)
    contents
  end

  defp write_store!(dir, map), do: write_store!(dir, Jason.encode!(map, pretty: true))

  defp read_store!(dir), do: Jason.decode!(File.read!(store_path(dir)))

  defp opts(dir, marker), do: [homeassistant_path: dir, port_migration_marker: marker]

  defp marker_opts(marker), do: [port_migration_marker: marker]

  describe "the migration" do
    test "rewrites data.stable.server_port 8123 -> 80 and nothing else" do
      dir = tmp_volume()
      marker = tmp_marker()
      before = store()
      write_store!(dir, before)

      assert :migrated = PortMigration.run(opts(dir, marker))

      # Every other field — envelope, the rest of `stable`, `pending`,
      # `yaml_migration_done` — survives untouched.
      assert read_store!(dir) == put_in(before, ["data", "stable", "server_port"], 80)
      assert get_in(read_store!(dir), ["data", "stable", "server_port"]) == 80

      # The rewrite alone marks nothing: Core has not bound 80 yet, and might
      # never (bind failure, or a running Core re-persisting its own 8123).
      refute File.exists?(marker)
    end

    test "writes the store back as the 2-space-pretty JSON Core itself writes" do
      dir = tmp_volume()
      write_store!(dir, store())

      assert :migrated = PortMigration.run(opts(dir, tmp_marker()))

      contents = File.read!(store_path(dir))

      assert contents ==
               Jason.encode!(put_in(store(), ["data", "stable", "server_port"], 80), pretty: true)

      assert Jason.decode!(contents)["data"]["stable"]["server_port"] == 80
    end

    test "leaves no tmp file behind and keeps the store's 0600 mode" do
      dir = tmp_volume()
      write_store!(dir, store())
      File.chmod!(store_path(dir), 0o600)

      assert :migrated = PortMigration.run(opts(dir, tmp_marker()))

      assert File.ls!(Path.join(dir, ".storage")) == ["http"]
      assert Bitwise.band(File.stat!(store_path(dir)).mode, 0o777) == 0o600
    end

    test "an absent \"pending\" key counts as no pending config" do
      dir = tmp_volume()
      marker = tmp_marker()
      write_store!(dir, update_in(store()["data"], &Map.delete(&1, "pending")))

      assert :migrated = PortMigration.run(opts(dir, marker))
      assert read_store!(dir)["data"]["stable"]["server_port"] == 80
      refute File.exists?(marker)
    end

    test "a Core that re-persisted 8123 before ever serving 80 is migrated again" do
      # The reason the marker is not written at rewrite time: Core's own
      # bind-failure fallback, or a still-running Core saving its in-memory
      # 8123, puts the fossil straight back.
      dir = tmp_volume()
      marker = tmp_marker()
      write_store!(dir, store())

      assert :migrated = PortMigration.run(opts(dir, marker))

      write_store!(dir, store())
      assert :migrated = PortMigration.run(opts(dir, marker))
      assert read_store!(dir)["data"]["stable"]["server_port"] == 80
    end
  end

  describe "conditions that keep it out of the way" do
    test "marker present -> no-op, the store is not even opened" do
      dir = tmp_volume()
      marker = tmp_marker()
      File.mkdir_p!(Path.dirname(marker))
      File.write!(marker, "confirmed 80 at 2026-08-07T00:00:00Z\n")
      # A user who has since moved Core back to the legacy port: the fossil
      # shape is indistinguishable from the migration's trigger, which is
      # exactly why a confirmed device stops looking.
      contents = write_store!(dir, store())

      assert {:skipped, :already_migrated} = PortMigration.run(opts(dir, marker))
      assert File.read!(store_path(dir)) == contents
    end

    test "a pending config is staged -> no-op, no marker (the user is mid-decision)" do
      dir = tmp_volume()
      marker = tmp_marker()
      pending = %{"server_port" => 8443, "error" => nil, "error_message" => nil}
      contents = write_store!(dir, store(%{"pending" => pending}))

      assert {:skipped, :pending_config} = PortMigration.run(opts(dir, marker))
      assert File.read!(store_path(dir)) == contents
      refute File.exists?(marker)
    end

    test "some other stable port -> no-op AND no marker, so a later 8123 can still migrate" do
      dir = tmp_volume()
      marker = tmp_marker()
      contents = write_store!(dir, with_stable_port(8080))

      assert {:skipped, {:other_port, 8080}} = PortMigration.run(opts(dir, marker))
      assert File.read!(store_path(dir)) == contents
      refute File.exists?(marker)

      # ... and it really does still migrate once the fossil shows up.
      write_store!(dir, store())
      assert :migrated = PortMigration.run(opts(dir, marker))
      assert read_store!(dir)["data"]["stable"]["server_port"] == 80
    end

    test "stable port already 80 -> no-op, and still no marker (the store is not proof)" do
      dir = tmp_volume()
      marker = tmp_marker()
      contents = write_store!(dir, with_stable_port(80))

      assert {:skipped, :already_target} = PortMigration.run(opts(dir, marker))
      assert File.read!(store_path(dir)) == contents
      refute File.exists?(marker)

      # An unconfirmed device keeps re-checking, and keeps no-opping.
      assert {:skipped, :already_target} = PortMigration.run(opts(dir, marker))
    end

    test "no marker path configured (host/test) -> disabled, nothing is read or written" do
      dir = tmp_volume()
      contents = write_store!(dir, store())

      assert {:skipped, :disabled} = PortMigration.run(homeassistant_path: dir)
      assert File.read!(store_path(dir)) == contents
    end

    test "no store file at all -> no-op, no marker (Core has never run here)" do
      dir = tmp_volume()
      marker = tmp_marker()

      assert {:skipped, :no_store} = PortMigration.run(opts(dir, marker))
      refute File.exists?(marker)
      refute File.exists?(store_path(dir))
    end
  end

  describe "unreadable / unparseable / unexpected stores" do
    test "corrupt JSON -> no-op warning, the file is left exactly as it was, no marker" do
      dir = tmp_volume()
      marker = tmp_marker()
      contents = write_store!(dir, ~s({"version": 2, "data": {"stable": {"server_p))

      log =
        capture_log(fn ->
          assert {:skipped, :unparseable} = PortMigration.run(opts(dir, marker))
        end)

      assert log =~ "not valid JSON"
      # The position, never the bytes — same discipline as `Vagus.Core.HttpConfig`.
      assert log =~ "position"
      refute log =~ "server_p\""
      assert File.read!(store_path(dir)) == contents
      refute File.exists?(marker)
    end

    test "valid JSON that isn't an object -> no-op warning, no marker" do
      dir = tmp_volume()
      marker = tmp_marker()
      write_store!(dir, ~s([1, 2, 3]))

      log =
        capture_log(fn ->
          assert {:skipped, :unexpected_shape} = PortMigration.run(opts(dir, marker))
        end)

      assert log =~ "not a JSON object"
      refute File.exists?(marker)
    end

    test "no readable data.stable.server_port -> no-op warning, no marker" do
      dir = tmp_volume()
      marker = tmp_marker()

      for shape <- [
            %{"version" => 2, "key" => "http"},
            %{"data" => %{"pending" => nil}},
            %{"data" => %{"stable" => %{"server_port" => "8123"}}}
          ] do
        contents = write_store!(dir, shape)

        log =
          capture_log(fn ->
            assert {:skipped, :unexpected_shape} = PortMigration.run(opts(dir, marker))
          end)

        assert log =~ "no readable data.stable.server_port"
        assert File.read!(store_path(dir)) == contents
        refute File.exists?(marker)
      end
    end

    test "an unreadable store -> no-op warning, no marker" do
      dir = tmp_volume()
      marker = tmp_marker()
      # A directory where the store file should be: `File.read/1` answers
      # :eisdir for any uid, unlike a mode-based block.
      File.mkdir_p!(store_path(dir))

      log =
        capture_log(fn ->
          assert {:skipped, {:unreadable, :eisdir}} = PortMigration.run(opts(dir, marker))
        end)

      assert log =~ "could not read"
      refute File.exists?(marker)
    end
  end

  describe "failures never block a Core start" do
    test "a write failure leaves the original store intact, cleans up, and writes no marker" do
      dir = tmp_volume()
      marker = tmp_marker()
      contents = write_store!(dir, store())
      # Block the tmp file the atomic rewrite has to create.
      File.mkdir_p!(store_path(dir) <> ".vagus-tmp")

      log =
        capture_log(fn ->
          assert {:error, :eisdir} = PortMigration.run(opts(dir, marker))
        end)

      assert log =~ "could not rewrite"
      assert log =~ "keeps serving 8123"
      assert File.read!(store_path(dir)) == contents
      refute File.exists?(marker)
    end

    test "a marker write failure leaves the device unconfirmed, and that is survivable" do
      dir = tmp_volume()
      marker = unwritable_marker()
      write_store!(dir, store())

      assert :migrated = PortMigration.run(opts(dir, marker))

      log =
        capture_log(fn ->
          assert {:error, :enotdir} = PortMigration.confirm(marker_opts(marker))
        end)

      assert log =~ "could not write the marker"

      # Re-checking costs one read of a store that is already on 80.
      assert {:skipped, :already_target} = PortMigration.run(opts(dir, marker))
    end
  end

  describe "confirm/1 — the only thing that writes the marker" do
    test "writes it once, then no-ops" do
      marker = tmp_marker()

      assert :ok = PortMigration.confirm(marker_opts(marker))
      assert File.read!(marker) =~ "confirmed 80"

      File.write!(marker, "untouched")
      assert {:skipped, :already_confirmed} = PortMigration.confirm(marker_opts(marker))
      assert File.read!(marker) == "untouched"
    end

    test "no marker path configured (host/test) -> disabled, nothing is written" do
      assert {:skipped, :disabled} = PortMigration.confirm()
    end

    test "a confirmation that cannot be written is logged and dropped" do
      marker = unwritable_marker()

      log =
        capture_log(fn ->
          assert {:error, :enotdir} = PortMigration.confirm(marker_opts(marker))
        end)

      assert log =~ "could not write the marker"
      refute File.exists?(marker)
    end

    test "a confirmed device never migrates again, whatever the store says" do
      dir = tmp_volume()
      marker = tmp_marker()
      write_store!(dir, store())

      assert :migrated = PortMigration.run(opts(dir, marker))
      assert :ok = PortMigration.confirm(marker_opts(marker))

      # The user moves Core back to 8123 through the UI — their decision.
      contents = write_store!(dir, store())

      assert {:skipped, :already_migrated} = PortMigration.run(opts(dir, marker))
      assert File.read!(store_path(dir)) == contents
    end
  end

  describe "the ports it moves between" do
    test "target_port/0 and legacy_port/0 are Core's Supervisor default and its fallback" do
      assert PortMigration.target_port() == 80
      assert PortMigration.legacy_port() == 8123
      assert PortMigration.legacy_port() == Vagus.Core.HttpConfig.defaults().port
      assert PortMigration.target_port() in Vagus.Addon.Ports.reserved_host_ports()
    end
  end
end
