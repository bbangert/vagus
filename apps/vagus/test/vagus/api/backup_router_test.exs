defmodule Vagus.API.BackupRouterTest do
  @moduledoc """
  M4-P6-T2: the `/backups...` HTTP surface (§A4) — list/info/create/restore/
  download/upload/delete/reload, wired to `Vagus.Backups` + `Vagus.Addon.
  Manager`.

  Unlike most router tests, `Vagus.Backups` is a real supervised singleton
  whose backup directory is resolved once at `Vagus.Application` boot — so
  this file repoints it at a tmp dir via `Vagus.Backups.set_dir/2` (the same
  seam `Vagus.Addon.Store`'s tests use `{:put_catalog, ...}` for) instead of
  starting a private instance, since the router always talks to the
  singleton by its default name. `async: false`: it mutates that singleton
  plus the `:addon_backend`/`:addon_data_root` app env, and (per
  `test/vagus/api/router_test.exs`'s own comment) the async phase's
  empty-backups assertions complete before this file's sync-phase tests run.
  """
  use ExUnit.Case, async: false
  use Plug.Test

  alias Vagus.Addon.{Config, Registry, State}
  alias Vagus.Backups

  @opts Vagus.API.Router.init([])

  setup do
    prev_backend = Application.get_env(:vagus, :addon_backend)
    Application.put_env(:vagus, :addon_backend, Vagus.Addon.Backend.Fake)

    data_root =
      Path.join(System.tmp_dir!(), "vagus-backup-rt-#{System.unique_integer([:positive])}")

    prev_root = Application.get_env(:vagus, :addon_data_root)
    Application.put_env(:vagus, :addon_data_root, data_root)

    prev_dir = Backups.dir()
    :ok = Backups.set_dir(Path.join(data_root, "backup"))

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:vagus, :addon_backend, prev_backend),
        else: Application.delete_env(:vagus, :addon_backend)

      if prev_root,
        do: Application.put_env(:vagus, :addon_data_root, prev_root),
        else: Application.delete_env(:vagus, :addon_data_root)

      Backups.set_dir(prev_dir)
      File.rm_rf(data_root)
    end)

    %{data_root: data_root}
  end

  defp fixture_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Test Addon",
        "version" => "1.0",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "homeassistant/{arch}-addon-test",
        "host_network" => true
      })

    config
  end

  defp install(slug, data_root, state \\ :started) do
    config = fixture_config(slug)
    :ok = State.put(config, state)
    on_exit(fn -> State.delete(slug) end)

    data_dir = Path.join([data_root, "addons", "data", slug])
    File.mkdir_p!(data_dir)
    File.write!(Path.join(data_dir, "f.txt"), "hello")
    config
  end

  defp supervisor_call(method, path, body \\ nil) do
    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
    |> Vagus.API.Router.call(@opts)
  end

  defp addon_call(method, path, slug, grants \\ %{}, body \\ nil) do
    token = "tok-#{System.unique_integer([:positive])}"

    identity =
      Map.merge(
        %{
          slug: slug,
          services_role: %{},
          auth_api: false,
          discovery: [],
          hassio_api: false,
          hassio_role: "default"
        },
        grants
      )

    :ok = Registry.register(token, identity)
    on_exit(fn -> Registry.unregister_slug(slug) end)

    conn = conn(method, path, body && Jason.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn

    conn
    |> put_req_header("x-supervisor-token", token)
    |> Vagus.API.Router.call(@opts)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # Builds a REAL `multipart/form-data` raw body (W4) — exercises the
  # route-local `Plug.Parsers` call `handle_backup_upload/1` makes (B1),
  # unlike a `Plug.Test.conn/3` map body (which bypasses `Plug.Parsers`
  # entirely and would pass even if the real multipart pipeline broke).
  # `parts`: `{:file, name, filename, content_type, content}` or
  # `{:field, name, value}`.
  defp multipart_conn(path, parts) do
    boundary = "vagusTestBoundary#{System.unique_integer([:positive])}"

    conn(:post, path, build_multipart(boundary, parts))
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
  end

  defp build_multipart(boundary, parts) do
    parts_body =
      Enum.map_join(parts, "", fn
        {:file, name, filename, content_type, content} ->
          "--#{boundary}\r\n" <>
            ~s(content-disposition: form-data; name="#{name}"; filename="#{filename}"\r\n) <>
            "content-type: #{content_type}\r\n\r\n" <>
            content <> "\r\n"

        {:field, name, value} ->
          "--#{boundary}\r\n" <>
            "content-disposition: form-data; name=\"#{name}\"\r\n\r\n" <>
            value <> "\r\n"
      end)

    parts_body <> "--#{boundary}--\r\n"
  end

  defp create_backup(slug) do
    conn = supervisor_call(:post, "/backups/new/partial", %{"addons" => [slug]})
    assert conn.status == 200
    body(conn)["data"]["slug"]
  end

  describe "POST /backups/new/partial" do
    test "happy path: creates a backup listing the add-on, returns slug + job_id", %{
      data_root: dr
    } do
      install("core_partial", dr)

      conn = supervisor_call(:post, "/backups/new/partial", %{"addons" => ["core_partial"]})
      assert conn.status == 200
      data = body(conn)["data"]
      assert is_binary(data["slug"])
      assert is_binary(data["job_id"])
      assert String.length(data["job_id"]) == 32

      assert {:ok, %{backup: b}} = Backups.get(data["slug"])
      assert Enum.any?(b["addons"], &(&1["slug"] == "core_partial"))
    end

    test "a non-empty password -> 400" do
      conn =
        supervisor_call(:post, "/backups/new/partial", %{"addons" => [], "password" => "secret"})

      assert conn.status == 400
      assert body(conn)["message"] =~ "protected backups are not supported"
    end

    test "homeassistant: true -> 400" do
      conn =
        supervisor_call(:post, "/backups/new/partial", %{
          "addons" => [],
          "homeassistant" => true
        })

      assert conn.status == 400
      assert body(conn)["message"] =~ "Core backup not supported"
    end

    test "a non-empty folders list -> 400" do
      conn =
        supervisor_call(:post, "/backups/new/partial", %{"addons" => [], "folders" => ["share"]})

      assert conn.status == 400
      assert body(conn)["message"] =~ "folder backup not supported"
    end

    test "a not-installed addon slug -> 400, nothing created" do
      conn = supervisor_call(:post, "/backups/new/partial", %{"addons" => ["ghost"]})
      assert conn.status == 400
      assert body(conn)["message"] =~ "ghost"
      assert Backups.list() == []
    end

    test "addons: \"ALL\" resolves to every installed slug", %{data_root: dr} do
      install("core_all_a", dr)
      install("core_all_b", dr)

      conn = supervisor_call(:post, "/backups/new/partial", %{"addons" => "ALL"})
      assert conn.status == 200
      slug = body(conn)["data"]["slug"]

      {:ok, %{backup: b}} = Backups.get(slug)
      names = Enum.map(b["addons"], & &1["slug"])
      assert "core_all_a" in names
      assert "core_all_b" in names
    end

    test "is supervisor-only (403 for an add-on caller)", %{data_root: dr} do
      install("core_forbidden", dr)

      conn =
        conn(:post, "/backups/new/partial", Jason.encode!(%{"addons" => ["core_forbidden"]}))
        |> put_req_header("content-type", "application/json")

      token = "tok-#{System.unique_integer([:positive])}"

      :ok =
        Registry.register(token, %{
          slug: "core_forbidden",
          services_role: %{},
          auth_api: false,
          discovery: []
        })

      on_exit(fn -> Registry.unregister_slug("core_forbidden") end)

      conn = conn |> put_req_header("x-supervisor-token", token) |> Vagus.API.Router.call(@opts)
      assert conn.status == 403
    end
  end

  describe "GET /backups and /backups/info" do
    test "list shape: the pinned V1 entry keys", %{data_root: dr} do
      install("core_list", dr)
      slug = create_backup("core_list")

      conn = supervisor_call(:get, "/backups")
      assert conn.status == 200
      [entry] = body(conn)["data"]["backups"]

      assert entry["slug"] == slug
      assert entry["type"] == "partial"
      assert entry["protected"] == false
      assert entry["compressed"] == true
      assert entry["location"] == nil
      assert entry["locations"] == [nil]
      assert is_number(entry["size"])
      assert is_integer(entry["size_bytes"])

      assert entry["location_attributes"] == %{
               ".local" => %{"protected" => false, "size_bytes" => entry["size_bytes"]}
             }

      assert entry["content"] == %{
               "homeassistant" => false,
               "addons" => ["core_list"],
               "folders" => []
             }
    end

    test "info: same shape + days_until_stale", %{data_root: dr} do
      install("core_info", dr)
      _slug = create_backup("core_info")

      conn = supervisor_call(:get, "/backups/info")
      assert conn.status == 200
      data = body(conn)["data"]
      assert data["days_until_stale"] == 30
      assert [_entry] = data["backups"]
    end

    test "is supervisor-only (403)" do
      conn = addon_call(:get, "/backups", "whoever")
      assert conn.status == 403
    end
  end

  describe "GET /backups/{slug}/info" do
    test "detail shape", %{data_root: dr} do
      install("core_detail", dr)
      slug = create_backup("core_detail")

      conn = supervisor_call(:get, "/backups/#{slug}/info")
      assert conn.status == 200
      data = body(conn)["data"]

      assert data["slug"] == slug
      assert data["type"] == "partial"
      assert data["homeassistant"] == nil
      assert data["repositories"] == []
      assert data["folders"] == []
      assert data["extra"] == %{}
      assert [addon] = data["addons"]
      assert addon["slug"] == "core_detail"
      assert addon["version"] == "1.0"
    end

    test "unknown slug -> 404" do
      conn = supervisor_call(:get, "/backups/nosuch/info")
      assert conn.status == 404
      assert body(conn)["message"] =~ "does not exist"
    end
  end

  describe "GET /backups/{slug}/download" do
    test "raw tar bytes + attachment headers", %{data_root: dr} do
      install("core_dl", dr)
      slug = create_backup("core_dl")
      {:ok, %{path: path}} = Backups.get(slug)
      expected = File.read!(path)

      conn = supervisor_call(:get, "/backups/#{slug}/download")
      assert conn.status == 200
      assert conn.resp_body == expected
      assert get_resp_header(conn, "content-type") == ["application/tar"]

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment; filename="
      assert disposition =~ ".tar"
    end

    test "unknown slug -> 404" do
      conn = supervisor_call(:get, "/backups/nosuch/download")
      assert conn.status == 404
    end
  end

  describe "POST /backups/new/upload (real multipart, W4/B1)" do
    test "a real multipart upload with a valid tar -> {slug}" do
      spec = %{slug: "up1", name: "Uploaded", addons: []}
      {:ok, tar} = Vagus.Backup.create(spec, date: "2026-07-21T00:00:00Z")

      conn =
        multipart_conn("/backups/new/upload", [
          {:file, "file", "backup.tar", "application/tar", tar}
        ])
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 200
      assert body(conn)["data"]["slug"] == "up1"
      assert {:ok, _entry} = Backups.get("up1")
    end

    test "garbage bytes inside a real multipart body -> 400" do
      garbage = :crypto.strong_rand_bytes(256)

      conn =
        multipart_conn("/backups/new/upload", [
          {:file, "file", "junk.tar", "application/tar", garbage}
        ])
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 400
    end

    test "a real multipart body with no file part -> 400" do
      conn =
        multipart_conn("/backups/new/upload", [{:field, "note", "no file attached"}])
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 400
    end

    test "a non-multipart content-type POST to this route -> 400, not 415/500" do
      conn =
        conn(:post, "/backups/new/upload", "just some bytes")
        |> put_req_header("content-type", "text/plain")
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 400
    end

    test "an add-on (non-supervisor) caller's multipart POST gets 403 without the body being parsed" do
      slug = "core_upload_forbidden"
      token = "tok-#{System.unique_integer([:positive])}"

      :ok =
        Registry.register(token, %{slug: slug, services_role: %{}, auth_api: false, discovery: []})

      on_exit(fn -> Registry.unregister_slug(slug) end)

      conn =
        multipart_conn("/backups/new/upload", [{:field, "note", "irrelevant"}])
        |> put_req_header("x-supervisor-token", token)
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 403
    end

    test "a multipart POST to a non-upload route is passed through unread, not 415/500" do
      conn =
        multipart_conn("/supervisor/reload", [{:field, "note", "irrelevant"}])
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 200
    end
  end

  describe "POST /backups/{slug}/restore/partial" do
    test "happy path: restores files + options, returns job_id", %{data_root: dr} do
      install("core_restore", dr)
      slug = create_backup("core_restore")

      data_dir = Path.join([dr, "addons", "data", "core_restore"])
      File.write!(Path.join(data_dir, "f.txt"), "mutated")

      conn =
        supervisor_call(:post, "/backups/#{slug}/restore/partial", %{"addons" => ["core_restore"]})

      assert conn.status == 200
      assert is_binary(body(conn)["data"]["job_id"])
      assert File.read!(Path.join(data_dir, "f.txt")) == "hello"
    end

    test "a non-empty password -> 400", %{data_root: dr} do
      install("core_restore_pw", dr)
      slug = create_backup("core_restore_pw")

      conn =
        supervisor_call(:post, "/backups/#{slug}/restore/partial", %{
          "addons" => ["core_restore_pw"],
          "password" => "x"
        })

      assert conn.status == 400
      assert body(conn)["message"] =~ "protected backups are not supported"
    end

    test "homeassistant: true -> 400", %{data_root: dr} do
      install("core_restore_ha", dr)
      slug = create_backup("core_restore_ha")

      conn =
        supervisor_call(:post, "/backups/#{slug}/restore/partial", %{
          "addons" => ["core_restore_ha"],
          "homeassistant" => true
        })

      assert conn.status == 400
      assert body(conn)["message"] =~ "Core restore not supported"
    end

    test "unknown backup slug -> 404" do
      conn = supervisor_call(:post, "/backups/nosuch/restore/partial", %{"addons" => []})
      assert conn.status == 404
    end

    test "an addon not in the backup -> 400", %{data_root: dr} do
      install("core_restore_present", dr)
      install("core_restore_ghost", dr)
      slug = create_backup("core_restore_present")

      conn =
        supervisor_call(:post, "/backups/#{slug}/restore/partial", %{
          "addons" => ["core_restore_ghost"]
        })

      assert conn.status == 400
      assert body(conn)["message"] =~ "not in backup"
    end
  end

  # The save path validates posted options against the add-on's schema; until
  # now the restore path did not, so a tar's `user.options` went to
  # `State.put_options/2` verbatim. That asymmetry was survivable while
  # `/backups` was supervisor-only. Since audit A4 a `hassio_role: backup`
  # add-on can upload an attacker-authored tar and restore it onto a PEER, at
  # which point "whatever the tar says" is caller-controlled input to another
  # add-on's configuration.
  describe "restore: options are validated against the installed schema" do
    defp install_with_schema(slug, data_root, schema, options) do
      {:ok, config} =
        Config.parse(%{
          "name" => "Schema Addon",
          "version" => "1.0",
          "slug" => slug,
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "schema" => schema
        })

      :ok = State.put(config, :stopped)
      :ok = State.put_options(slug, options)
      on_exit(fn -> State.delete(slug) end)

      data_dir = Path.join([data_root, "addons", "data", slug])
      File.mkdir_p!(data_dir)
      File.write!(Path.join(data_dir, "f.txt"), "hello")
      config
    end

    test "options that still validate are restored", %{data_root: dr} do
      install_with_schema("core_sch_ok", dr, %{"greeting" => "str"}, %{"greeting" => "hi"})
      slug = create_backup("core_sch_ok")

      :ok = State.put_options("core_sch_ok", %{"greeting" => "changed"})

      conn =
        supervisor_call(:post, "/backups/#{slug}/restore/partial", %{"addons" => ["core_sch_ok"]})

      assert conn.status == 200
      assert {:ok, %{user_options: %{"greeting" => "hi"}}} = State.get("core_sch_ok")
    end

    test "options that no longer validate are dropped, and the file restore still completes",
         %{data_root: dr} do
      install_with_schema("core_sch_bad", dr, %{"greeting" => "str"}, %{"greeting" => "hi"})
      slug = create_backup("core_sch_bad")

      # The add-on's schema tightened since the backup — same code path an
      # attacker-authored tar takes, without needing to forge one.
      {:ok, tightened} =
        Config.parse(%{
          "name" => "Schema Addon",
          "version" => "2.0",
          "slug" => "core_sch_bad",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "homeassistant/{arch}-addon-test",
          "schema" => %{"greeting" => "int"}
        })

      :ok = State.put(tightened, :stopped)
      :ok = State.put_options("core_sch_bad", %{"greeting" => 42})

      data_dir = Path.join([dr, "addons", "data", "core_sch_bad"])
      File.write!(Path.join(data_dir, "f.txt"), "mutated")

      conn =
        supervisor_call(:post, "/backups/#{slug}/restore/partial", %{"addons" => ["core_sch_bad"]})

      # The restore is NOT failed — the data dir is already swapped by the
      # time options are written, and a half-restored add-on is worse than one
      # that kept its current options.
      assert conn.status == 200
      assert File.read!(Path.join(data_dir, "f.txt")) == "hello"
      assert {:ok, %{user_options: %{"greeting" => 42}}} = State.get("core_sch_bad")
    end
  end

  # Audit W3. The 256MB disk-spooling multipart parse was bounded by
  # "supervisor-only" until A4 widened the family to ROLE_BACKUP. Serialising
  # uploads keeps the worst case at one spool rather than N.
  describe "POST /backups/new/upload — one at a time" do
    test "a second concurrent upload is refused with 429" do
      parent = self()

      holder =
        spawn(fn ->
          :ok = Backups.acquire_upload_slot()
          send(parent, :held)
          receive do: (:release -> Backups.release_upload_slot())
        end)

      assert_receive :held

      conn =
        multipart_conn("/backups/new/upload", [{:field, "note", "irrelevant"}])
        |> put_req_header("authorization", "Bearer #{Vagus.API.Token.get()}")
        |> Vagus.API.Router.call(@opts)

      assert conn.status == 429
      assert body(conn)["message"] =~ "already in progress"

      send(holder, :release)
    end

    test "the slot is released when its holder dies, not leaked" do
      parent = self()

      holder =
        spawn(fn ->
          :ok = Backups.acquire_upload_slot()
          send(parent, :held)
          receive do: (:never -> :ok)
        end)

      assert_receive :held
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      # The monitor in Backups fires asynchronously; retry briefly rather than
      # sleeping a fixed amount.
      assert eventually(fn -> Backups.acquire_upload_slot() == :ok end)
      Backups.release_upload_slot()
    end

    defp eventually(fun, attempts \\ 50) do
      Enum.reduce_while(1..attempts, false, fn _i, _acc ->
        if fun.(), do: {:halt, true}, else: {:cont, false}
      end)
    end
  end

  describe "DELETE /backups/{slug}" do
    test "removes the backup", %{data_root: dr} do
      install("core_delete", dr)
      slug = create_backup("core_delete")

      conn = supervisor_call(:delete, "/backups/#{slug}")
      assert conn.status == 200
      assert :error = Backups.get(slug)
    end

    test "unknown slug -> 404" do
      conn = supervisor_call(:delete, "/backups/nosuch")
      assert conn.status == 404
    end

    test "a default-role add-on is refused (403)" do
      conn = addon_call(:delete, "/backups/whatever", "whoever")
      assert conn.status == 403
    end
  end

  describe "POST /backups/reload" do
    test "rescans the backup dir and returns ok", %{data_root: dr} do
      install("core_reload", dr)
      slug = create_backup("core_reload")

      conn = supervisor_call(:post, "/backups/reload")
      assert conn.status == 200
      assert {:ok, _} = Backups.get(slug)
    end
  end

  # Audit A4. Upstream grants `/backups.*` to `ROLE_BACKUP` (security.py
  # L123-128) — the role exists for exactly this: a backup add-on driving the
  # surface on the user's behalf. Vagus held the whole family at
  # `supervisor_only/2`, so declaring `hassio_role: backup` bought nothing and
  # every such add-on saw a 403 where the real Supervisor answers.
  describe "tier: ROLE_BACKUP" do
    @backup_role %{hassio_api: true, hassio_role: "backup"}
    @manager_role %{hassio_api: true, hassio_role: "manager"}

    test "a backup-role add-on may list, create, read, download and delete",
         %{data_root: dr} do
      install("core_backup_role", dr)

      created =
        addon_call(:post, "/backups/new/partial", "core_backup_addon", @backup_role, %{
          "addons" => ["core_backup_role"]
        })

      assert created.status == 200
      slug = body(created)["data"]["slug"]

      assert addon_call(:get, "/backups", "core_backup_addon_2", @backup_role).status == 200
      assert addon_call(:get, "/backups/info", "core_backup_addon_3", @backup_role).status == 200

      assert addon_call(:get, "/backups/#{slug}/info", "core_backup_addon_4", @backup_role).status ==
               200

      assert addon_call(
               :get,
               "/backups/#{slug}/download",
               "core_backup_addon_5",
               @backup_role
             ).status == 200

      assert addon_call(:delete, "/backups/#{slug}", "core_backup_addon_6", @backup_role).status ==
               200

      assert :error = Backups.get(slug)
    end

    test "a manager-role add-on reaches it too — manager's list has /backups.* as well" do
      assert addon_call(:get, "/backups", "core_backup_manager", @manager_role).status == 200
    end

    test "the backup role does NOT leak into the manager surface" do
      assert addon_call(:get, "/store", "core_backup_scoped", @backup_role).status == 403
      assert addon_call(:get, "/mounts", "core_backup_scoped_2", @backup_role).status == 403
    end

    # `/.+/info` is `role_access[default]`, and it is checked before
    # `/backups.*` upstream as well — so the two info reads sit one tier lower
    # than the rest of the family. Pinned because it looks like a bug.
    test "the two /backups info reads are default-tier, deliberately" do
      plain = %{hassio_api: true, hassio_role: "default"}

      assert addon_call(:get, "/backups/info", "core_backup_default", plain).status == 200

      assert addon_call(:get, "/backups/nosuch/info", "core_backup_default_2", plain).status ==
               404

      assert addon_call(:get, "/backups", "core_backup_default_3", plain).status == 403
    end
  end
end
