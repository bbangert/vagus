defmodule Vagus.BackupsTest do
  @moduledoc """
  M4-P6-T2: `Vagus.Backups`' on-disk store (scan/index/list/get/delete) and
  the `create_partial`/`restore_partial` orchestration on top of it (§A4).

  Each test starts its own named `Vagus.Backups` instance pointed at a tmp
  dir (never touches the app's supervised singleton) but does read/write the
  real (globally-supervised) `Vagus.Addon.State` — same pattern
  `test/vagus/addon/manager_test.exs` uses. `async: false` because
  `Vagus.Addon.Backend.Fake`'s call recorder is a single global table.
  """
  use ExUnit.Case, async: false

  alias Vagus.Addon.{Backend, Config, State}
  alias Vagus.Backups

  @backend Backend.Fake

  setup do
    data_root = Path.join(System.tmp_dir!(), "vagus-bk-#{System.unique_integer([:positive])}")
    backup_dir = Path.join(data_root, "backup")
    server = :"backups_test_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Backups.start_link(name: server, dir: backup_dir)
    on_exit(fn -> File.rm_rf(data_root) end)
    %{data_root: data_root, backup_dir: backup_dir, server: server}
  end

  defp fixture_config(slug, overrides) do
    base = %{
      "name" => "Test Addon",
      "version" => "1.0",
      "slug" => slug,
      "description" => "d",
      "arch" => ["amd64"],
      "image" => "homeassistant/{arch}-addon-test",
      "host_network" => true
    }

    {:ok, config} = Config.parse(Map.merge(base, overrides))
    config
  end

  # Seeds `Vagus.Addon.State` (the real, globally-supervised singleton) and
  # creates the add-on's data dir under `data_root`, scheduling both for
  # cleanup.
  defp install(slug, data_root, state \\ :started, user_options \\ %{}, overrides \\ %{}) do
    config = fixture_config(slug, overrides)
    :ok = State.put(config, state, user_options: user_options)
    on_exit(fn -> State.delete(slug) end)

    data_dir = Path.join([data_root, "addons", "data", slug])
    File.mkdir_p!(data_dir)
    config
  end

  defp data_dir(data_root, slug), do: Path.join([data_root, "addons", "data", slug])

  describe "scan/index (GenServer)" do
    test "a tar written directly into the dir is picked up on reload", %{
      backup_dir: dir,
      server: server
    } do
      spec = %{slug: "abc12345", name: "Direct backup", addons: []}
      {:ok, tar} = Vagus.Backup.create(spec, date: "2026-01-01T00:00:00Z")
      File.write!(Path.join(dir, "abc12345.tar"), tar)

      :ok = Backups.reload(server)

      assert [%{backup: %{"slug" => "abc12345"}}] = Backups.list(server)
      assert {:ok, %{backup: %{"name" => "Direct backup"}}} = Backups.get("abc12345", server)
    end

    test "get/2 on an unknown slug is :error", %{server: server} do
      assert :error = Backups.get("nope", server)
    end

    test "put_file/2 rejects a non-tar payload", %{server: server} do
      assert {:error, _reason} = Backups.put_file("not a tar", server)
      assert Backups.list(server) == []
    end
  end

  describe "create_partial/3" do
    test "an installed hot add-on: tar written + indexed, content lists the add-on", %{
      data_root: dr,
      server: server
    } do
      slug = "core_hot"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "state.txt"), "hello")

      assert {:ok, backup_slug} =
               Backups.create_partial(nil, [slug],
                 server: server,
                 data_root: dr,
                 date: "2026-07-21T00:00:00Z"
               )

      assert {:ok, %{backup: b, path: path}} = Backups.get(backup_slug, server)
      assert b["name"] =~ "Partial backup"
      assert Enum.any?(b["addons"], &(&1["slug"] == slug))
      assert File.exists?(path)

      {:ok, tar} = File.read(path)
      {:ok, %{addon: addon, data: files}} = Vagus.Backup.extract_addon(tar, slug)
      assert addon["state"] == "started"
      assert Map.new(files)["state.txt"] == "hello"
    end

    test "a not-installed slug aborts before anything is written", %{
      data_root: dr,
      server: server
    } do
      assert {:error, {:not_installed, "ghost"}} =
               Backups.create_partial(nil, ["ghost"], server: server, data_root: dr)

      assert Backups.list(server) == []
    end

    test "a cold-mode add-on is stopped before the snapshot and restarted after", %{
      data_root: dr,
      server: server
    } do
      slug = "core_cold"
      install(slug, dr, :started, %{}, %{"backup" => "cold"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      :ok = @backend.reset_calls()

      assert {:ok, _backup_slug} =
               Backups.create_partial(nil, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      calls = @backend.calls()
      assert Enum.any?(calls, &match?({:stop, "addon_" <> ^slug}, &1))
      assert Enum.any?(calls, &match?({:start, _}, &1))
      assert {:ok, %{state: :started}} = State.get(slug)
    end

    test "a stopped add-on is snapshotted as-is (no stop/start either way)", %{
      data_root: dr,
      server: server
    } do
      slug = "core_stopped"
      install(slug, dr, :stopped, %{}, %{"backup" => "cold"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      :ok = @backend.reset_calls()

      assert {:ok, backup_slug} =
               Backups.create_partial(nil, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert @backend.calls() == []
      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      {:ok, tar} = File.read(path)
      {:ok, %{addon: addon}} = Vagus.Backup.extract_addon(tar, slug)
      assert addon["state"] == "stopped"
    end
  end

  describe "restore_partial/3" do
    test "round-trip: files + user_options restored, add-on restarted (was started)", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore"
      install(slug, dr, :started, %{"greet" => "hi"})
      dd = data_dir(dr, slug)
      File.write!(Path.join(dd, "keep.txt"), "original")

      {:ok, backup_slug} =
        Backups.create_partial(nil, [slug],
          server: server,
          data_root: dr,
          date: "2026-07-21T00:00:00Z"
        )

      # Drift after the backup was taken.
      File.write!(Path.join(dd, "keep.txt"), "mutated")
      File.write!(Path.join(dd, "extra.txt"), "should be gone")
      :ok = State.put_options(slug, %{"greet" => "bye"})

      :ok = @backend.reset_calls()

      assert :ok =
               Backups.restore_partial(backup_slug, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert File.read!(Path.join(dd, "keep.txt")) == "original"
      refute File.exists?(Path.join(dd, "extra.txt"))
      assert {:ok, %{user_options: %{"greet" => "hi"}}} = State.get(slug)

      calls = @backend.calls()
      assert Enum.any?(calls, &match?({:stop, "addon_" <> ^slug}, &1))
      assert Enum.any?(calls, &match?({:start, _}, &1))
    end

    test "a stopped-at-backup-time add-on is not restarted on restore", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_stopped"
      install(slug, dr, :stopped)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      :ok = @backend.reset_calls()

      assert :ok =
               Backups.restore_partial(backup_slug, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      refute Enum.any?(@backend.calls(), &match?({:start, _}, &1))
    end

    test "restore onto a not-installed slug errors", %{data_root: dr, server: server} do
      slug = "core_src"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      State.delete(slug)

      assert {:error, message} =
               Backups.restore_partial(backup_slug, [slug], server: server, data_root: dr)

      assert message =~ "is not installed"
    end

    test "restore of a slug absent from the backup errors", %{data_root: dr, server: server} do
      slug = "core_present"
      ghost = "core_ghost"
      install(slug, dr)
      install(ghost, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      assert {:error, message} =
               Backups.restore_partial(backup_slug, [ghost], server: server, data_root: dr)

      assert message =~ "not in backup"
    end

    test "restoring an unknown backup slug errors", %{data_root: dr, server: server} do
      assert {:error, _reason} =
               Backups.restore_partial("nosuchbk", ["whatever"], server: server, data_root: dr)
    end
  end

  describe "delete/2" do
    test "removes the tar file + index entry", %{data_root: dr, server: server} do
      slug = "core_del"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      assert File.exists?(path)

      assert :ok = Backups.delete(backup_slug, server)
      refute File.exists?(path)
      assert :error = Backups.get(backup_slug, server)
      assert :error = Backups.delete(backup_slug, server)
    end
  end
end
