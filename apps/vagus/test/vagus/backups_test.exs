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
      spec = %{
        slug: "abc12345",
        name: "Direct backup",
        addons: [],
        supervisor_version: "2026.07.3"
      }

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

    # Intended, not incidental: `protected` is a per-install security setting,
    # not add-on data, so a restore of the add-on's `/data` must not silently
    # re-grant (or revoke) device access the user set independently. Only
    # `POST /addons/{slug}/security` moves it — `finish_restore/3` reaches
    # `State.put_options/2` alone.
    test "a restore leaves the add-on's protection mode untouched", %{
      data_root: dr,
      server: server
    } do
      slug = "core_restore_protected"
      install(slug, dr, :stopped, %{"greet" => "hi"})
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)

      # Turned off AFTER the backup was taken — the restore must not roll it
      # back to the protected default the tar knows nothing about.
      :ok = State.put_setting(slug, :protected, false)

      assert :ok =
               Backups.restore_partial(backup_slug, [slug],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert {:ok, %{protected: false, user_options: %{"greet" => "hi"}}} = State.get(slug)
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

    test "pre-flight (W2): a later slug failing means an earlier slug is never touched", %{
      data_root: dr,
      server: server
    } do
      slug = "core_preflight_ok"
      ghost = "core_preflight_missing"
      install(slug, dr)
      install(ghost, dr)
      File.write!(Path.join(data_dir(dr, slug), "keep.txt"), "original")

      {:ok, backup_slug} =
        Backups.create_partial(nil, [slug], server: server, data_root: dr)

      :ok = @backend.reset_calls()

      assert {:error, message} =
               Backups.restore_partial(backup_slug, [slug, ghost],
                 server: server,
                 data_root: dr,
                 backend: @backend
               )

      assert message =~ "not in backup"
      # `slug` (which IS valid/installed/in-backup) must not have been
      # stopped/wiped just because `ghost` (checked second) fails pre-flight.
      assert @backend.calls() == []
      assert File.read!(Path.join(data_dir(dr, slug), "keep.txt")) == "original"
    end
  end

  # The upstream restore contract, asserted on the tar directly — the schema
  # IS the contract (plan P4-T7). A restoring HAOS coerces
  # `supervisor_version` through AwesomeVersion and compares it
  # (`backups/manager.py`), and validates each `addon.json` against
  # `SCHEMA_APP_BACKUP`, whose `system` is the full add-on config schema
  # plus a REQUIRED `repository` (`apps/validate.py`). These tests pin the
  # exact fields those checks read.
  describe "upstream restore contract (audit C2/C3/C5)" do
    test "backup.json: version-shaped supervisor_version, extra round-trip, MB sizes", %{
      data_root: dr,
      server: server
    } do
      slug = "core_contract"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "hello")

      extra = %{"supervisor.backup_request_date" => "2026-07-30T00:00:00Z"}

      {:ok, backup_slug} =
        Backups.create_partial(nil, [slug], server: server, data_root: dr, extra: extra)

      {:ok, %{backup: b, path: path}} = Backups.get(backup_slug, server)

      # A real version string, not "vagus" (C2) — and the SAME version the
      # API claims, so the tar and the wire tell one story.
      assert b["supervisor_version"] == Vagus.API.StaticData.supervisor_version()
      assert b["supervisor_version"] =~ ~r/^\d{4}\.\d{2}(\.\d+)?$/

      # Core keys automatic-backup identity off extra (C5).
      assert b["extra"] == extra

      # Per-addon size is an MB float (C5) — strictly smaller than the byte
      # count could ever be for a non-empty inner tar.
      assert [%{"size" => size}] = b["addons"]
      assert is_float(size) and size > 0 and size < 1

      # And the tar's own copy agrees with the index.
      {:ok, %{backup: from_disk}} = Vagus.Backup.read_file(path)
      assert from_disk["supervisor_version"] == b["supervisor_version"]
      assert from_disk["extra"] == extra
    end

    test "addon.json's system block satisfies SCHEMA_APP_SYSTEM's requirements", %{
      data_root: dr,
      server: server
    } do
      slug = "core_system"
      install(slug, dr)
      File.write!(Path.join(data_dir(dr, slug), "f.txt"), "x")

      {:ok, backup_slug} = Backups.create_partial(nil, [slug], server: server, data_root: dr)
      {:ok, %{path: path}} = Backups.get(backup_slug, server)
      {:ok, %{addon: addon}} = Vagus.Backup.extract_addon_file(path, slug)

      system = addon["system"]

      # The base add-on config schema's required keys…
      assert system["name"] == "Test Addon"
      assert system["version"] == "1.0"
      assert system["slug"] == slug
      assert system["description"] == "d"
      # …the shape-stable optionals a restore needs (availability + image)…
      assert system["arch"] == ["amd64"]
      assert system["image"] == "homeassistant/{arch}-addon-test"
      # …and SCHEMA_APP_SYSTEM's own required addition. Not in any store
      # repository here, so the detached fallback.
      assert system["repository"] == "core"

      # SCHEMA_APP_BACKUP's siblings.
      assert addon["user"]["version"] == "1.0"
      assert addon["state"] in ["started", "stopped"]
    end

    test "an old tar claiming supervisor_version \"vagus\" still indexes and lists", %{
      backup_dir: dir,
      server: server
    } do
      # Written by a pre-phase-4 Vagus — tolerated on read; it simply stays
      # HAOS-unrestorable (scratchpad decision, 2026-07-30).
      spec = %{slug: "0ldvagus", name: "Old tar", addons: [], supervisor_version: "vagus"}
      {:ok, tar} = Vagus.Backup.create(spec, date: "2026-01-01T00:00:00Z")
      File.write!(Path.join(dir, "0ldvagus.tar"), tar)

      :ok = Backups.reload(server)

      assert {:ok, %{backup: %{"supervisor_version" => "vagus"}}} =
               Backups.get("0ldvagus", server)
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
