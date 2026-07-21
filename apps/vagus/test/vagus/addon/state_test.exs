defmodule Vagus.Addon.StateTest do
  @moduledoc "Add-on state store (slug → config + lifecycle state + user options)."
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, State}

  setup do
    {:ok, c} =
      Config.parse(%{
        "name" => "Mosquitto broker",
        "version" => "7.1.0",
        "slug" => "core_mosquitto",
        "description" => "An Open Source MQTT broker",
        "arch" => ["aarch64"]
      })

    pid = start_supervised!({State, name: nil})
    %{config: c, s: pid}
  end

  test "put/get round-trips the config + state, defaulting user_options to %{}", %{
    config: c,
    s: s
  } do
    :ok = State.put(c, :started, server: s)

    assert {:ok, %{config: ^c, state: :started, user_options: %{}}} =
             State.get("core_mosquitto", s)
  end

  test "get on an unknown slug is :error", %{s: s} do
    assert :error = State.get("nope", s)
  end

  test "put replaces prior entry for the slug", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s)
    :ok = State.put(c, :stopped, server: s)
    assert {:ok, %{state: :stopped}} = State.get("core_mosquitto", s)
  end

  test "put with :user_options sets it explicitly", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s, user_options: %{"greeting" => "hi"})
    assert {:ok, %{user_options: %{"greeting" => "hi"}}} = State.get("core_mosquitto", s)
  end

  test "a start/stop transition without :user_options preserves previously-stored options", %{
    config: c,
    s: s
  } do
    :ok = State.put(c, :started, server: s, user_options: %{"greeting" => "hi"})
    :ok = State.put(c, :stopped, server: s)

    assert {:ok, %{state: :stopped, user_options: %{"greeting" => "hi"}}} =
             State.get("core_mosquitto", s)

    :ok = State.put(c, :started, server: s)

    assert {:ok, %{state: :started, user_options: %{"greeting" => "hi"}}} =
             State.get("core_mosquitto", s)
  end

  test "put_options replaces the stored user options for an installed slug", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s)
    assert :ok = State.put_options("core_mosquitto", %{"a" => 1}, s)
    assert {:ok, %{user_options: %{"a" => 1}}} = State.get("core_mosquitto", s)
  end

  test "put_options on an unknown slug is :error", %{s: s} do
    assert :error = State.put_options("nope", %{"a" => 1}, s)
  end

  test "delete removes the entry", %{config: c, s: s} do
    :ok = State.put(c, :started, server: s)
    :ok = State.delete("core_mosquitto", s)
    assert :error = State.get("core_mosquitto", s)
    assert State.list(s) == []
  end

  describe "persistence (M4-P8-T1)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "vagus-state-#{System.unique_integer([:positive])}")
      path = Path.join(dir, "addons.json")
      on_exit(fn -> File.rm_rf(dir) end)
      %{path: path}
    end

    # `id: make_ref()` so a test that starts more than one instance against
    # the same path (stop + restart) doesn't collide on the test
    # supervisor's default (module-derived) child id; `restart: :temporary`
    # so an explicit `GenServer.stop/1` is never auto-restarted underneath.
    defp start_persisted(path) do
      start_supervised!({State, name: nil, persist_path: path},
        id: make_ref(),
        restart: :temporary
      )
    end

    test "put persists {version, addons: {config, state, user_options}} to disk", %{
      config: c,
      path: path
    } do
      s = start_persisted(path)
      :ok = State.put(c, :started, server: s, user_options: %{"greeting" => "hi"})

      assert {:ok, on_disk} = Jason.decode(File.read!(path))
      assert on_disk["version"] == 1
      assert on_disk["addons"]["core_mosquitto"]["state"] == "started"
      assert on_disk["addons"]["core_mosquitto"]["user_options"] == %{"greeting" => "hi"}
      assert on_disk["addons"]["core_mosquitto"]["config"]["slug"] == "core_mosquitto"
    end

    test "put_options and delete each re-persist the file", %{config: c, path: path} do
      s = start_persisted(path)
      :ok = State.put(c, :started, server: s)
      :ok = State.put_options("core_mosquitto", %{"a" => 1}, s)

      assert {:ok, %{"addons" => addons1}} = Jason.decode(File.read!(path))
      assert addons1["core_mosquitto"]["user_options"] == %{"a" => 1}

      :ok = State.delete("core_mosquitto", s)
      assert {:ok, %{"addons" => addons2}} = Jason.decode(File.read!(path))
      assert addons2 == %{}
    end

    test "restarting with the same path restores entries (config round-tripped, state + options intact)",
         %{config: c, path: path} do
      s1 = start_persisted(path)
      :ok = State.put(c, :started, server: s1, user_options: %{"greeting" => "hi"})
      GenServer.stop(s1)

      s2 = start_persisted(path)

      assert {:ok, %{config: restored, state: :started, user_options: %{"greeting" => "hi"}}} =
               State.get("core_mosquitto", s2)

      assert restored == c
    end

    test "a corrupt (non-JSON) file starts empty and logs, without crashing init", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json at all {{{")

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          s = start_persisted(path)
          assert State.list(s) == []
        end)

      assert log =~ "not valid JSON"
    end

    test "an entry whose key doesn't match its config's slug is dropped", %{config: c, path: path} do
      File.mkdir_p!(Path.dirname(path))

      on_disk = %{
        "version" => 1,
        "addons" => %{
          "wrong_key" => %{
            "config" => Vagus.Addon.Config.to_persistable(c),
            "state" => "started",
            "user_options" => %{}
          }
        }
      }

      File.write!(path, Jason.encode!(on_disk))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          s = start_persisted(path)
          assert State.list(s) == []
        end)

      assert log =~ "dropping invalid/mismatched entry"
    end

    test "an entry with an unparseable config is dropped without crashing init", %{path: path} do
      File.mkdir_p!(Path.dirname(path))

      on_disk = %{
        "version" => 1,
        "addons" => %{
          "bad" => %{"config" => %{"not" => "a valid config"}, "state" => "started"}
        }
      }

      File.write!(path, Jason.encode!(on_disk))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          s = start_persisted(path)
          assert State.list(s) == []
        end)

      assert log =~ "dropping invalid/mismatched entry"
    end

    test "persist_path: nil never writes a file", %{config: c} do
      dir = Path.join(System.tmp_dir!(), "vagus-state-nil-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "addons.json")

      s = start_persisted(nil)
      :ok = State.put(c, :started, server: s)

      refute File.exists?(path)
      refute File.exists?(dir)
    end
  end
end
