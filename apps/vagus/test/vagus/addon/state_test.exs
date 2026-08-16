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

  describe "per-install settings (IW-P0-T2)" do
    test "a new entry gets a freshly generated token and default settings", %{config: c, s: s} do
      :ok = State.put(c, :started, server: s)

      assert {:ok,
              %{
                ingress_token: token,
                ingress_port: nil,
                ingress_panel: false,
                watchdog: false,
                boot: nil,
                auto_update: nil,
                protected: true
              }} = State.get("core_mosquitto", s)

      assert is_binary(token)
      assert token =~ ~r/^[-_A-Za-z0-9]+$/
    end

    test "protected survives a stop/start cycle once turned off", %{config: c, s: s} do
      # `handle_call({:put, ...})` rebuilds the entry on every lifecycle
      # transition. If `protected` were not in `preserved_settings/2`, a stop
      # would silently re-protect the add-on and its `full_access` grants
      # would vanish on the next start.
      :ok = State.put(c, :started, server: s)
      :ok = State.put_setting("core_mosquitto", :protected, false, s)

      :ok = State.put(c, :stopped, server: s)
      assert {:ok, %{protected: false}} = State.get("core_mosquitto", s)

      :ok = State.put(c, :started, server: s)
      assert {:ok, %{protected: false}} = State.get("core_mosquitto", s)
    end

    test "put_setting on an unknown key is a FunctionClauseError, not a silent write", %{s: s} do
      # The atom is built at runtime on purpose: Elixir 1.20's type checker
      # rejects a *literal* bad atom against the `key in [...]` guard at
      # compile time, so a direct call would fail the build rather than the
      # assertion.
      typo = String.to_atom("protecte_d")

      assert_raise FunctionClauseError, fn ->
        State.put_setting("core_mosquitto", typo, false, s)
      end
    end

    test "the ingress_token is generated once and stable across a later put/3", %{
      config: c,
      s: s
    } do
      :ok = State.put(c, :started, server: s)
      assert {:ok, %{ingress_token: token1}} = State.get("core_mosquitto", s)

      :ok = State.put(c, :stopped, server: s)
      assert {:ok, %{ingress_token: token2}} = State.get("core_mosquitto", s)

      assert token1 == token2
    end

    test "two different slugs get two different tokens", %{s: s} do
      {:ok, other} =
        Config.parse(%{
          "name" => "Other",
          "version" => "1",
          "slug" => "other",
          "description" => "d",
          "arch" => ["aarch64"]
        })

      {:ok, c} =
        Config.parse(%{
          "name" => "Mosquitto broker",
          "version" => "7.1.0",
          "slug" => "core_mosquitto",
          "description" => "An Open Source MQTT broker",
          "arch" => ["aarch64"]
        })

      :ok = State.put(c, :started, server: s)
      :ok = State.put(other, :started, server: s)

      assert {:ok, %{ingress_token: token1}} = State.get("core_mosquitto", s)
      assert {:ok, %{ingress_token: token2}} = State.get("other", s)
      assert token1 != token2
    end

    test "put_setting/4 writes ingress_port, ingress_panel, and watchdog", %{config: c, s: s} do
      :ok = State.put(c, :started, server: s)

      assert :ok = State.put_setting("core_mosquitto", :ingress_port, 62_001, s)
      assert :ok = State.put_setting("core_mosquitto", :ingress_panel, true, s)
      assert :ok = State.put_setting("core_mosquitto", :watchdog, true, s)

      assert {:ok,
              %{
                ingress_port: 62_001,
                ingress_panel: true,
                watchdog: true
              }} = State.get("core_mosquitto", s)
    end

    test "put_setting/4 writes boot and auto_update (phase 6 chunk A)", %{config: c, s: s} do
      :ok = State.put(c, :started, server: s)

      assert :ok = State.put_setting("core_mosquitto", :boot, "manual", s)
      assert :ok = State.put_setting("core_mosquitto", :auto_update, true, s)

      assert {:ok, %{boot: "manual", auto_update: true}} = State.get("core_mosquitto", s)

      assert :ok = State.put_setting("core_mosquitto", :auto_update, false, s)
      assert {:ok, %{auto_update: false}} = State.get("core_mosquitto", s)
    end

    test "put_setting/4 preserves the other settings and user_options", %{config: c, s: s} do
      :ok = State.put(c, :started, server: s, user_options: %{"greeting" => "hi"})
      :ok = State.put_setting("core_mosquitto", :watchdog, true, s)

      assert {:ok, %{user_options: %{"greeting" => "hi"}, watchdog: true, ingress_panel: false}} =
               State.get("core_mosquitto", s)
    end

    test "put_setting/4 on an unknown slug is :error", %{s: s} do
      assert :error = State.put_setting("nope", :watchdog, true, s)
    end
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
      assert is_binary(on_disk["addons"]["core_mosquitto"]["ingress_token"])
      assert on_disk["addons"]["core_mosquitto"]["ingress_port"] == nil
      assert on_disk["addons"]["core_mosquitto"]["ingress_panel"] == false
      assert on_disk["addons"]["core_mosquitto"]["watchdog"] == false
      assert on_disk["addons"]["core_mosquitto"]["boot"] == nil
      assert on_disk["addons"]["core_mosquitto"]["auto_update"] == nil
      assert on_disk["addons"]["core_mosquitto"]["protected"] == true
    end

    test "put_setting persists across a reload, and the ingress_token survives the round-trip", %{
      config: c,
      path: path
    } do
      s1 = start_persisted(path)
      :ok = State.put(c, :started, server: s1)
      assert {:ok, %{ingress_token: token}} = State.get("core_mosquitto", s1)

      :ok = State.put_setting("core_mosquitto", :ingress_port, 62_001, s1)
      :ok = State.put_setting("core_mosquitto", :ingress_panel, true, s1)
      :ok = State.put_setting("core_mosquitto", :watchdog, true, s1)
      :ok = State.put_setting("core_mosquitto", :boot, "manual", s1)
      :ok = State.put_setting("core_mosquitto", :auto_update, true, s1)
      :ok = State.put_setting("core_mosquitto", :protected, false, s1)
      GenServer.stop(s1)

      s2 = start_persisted(path)

      assert {:ok,
              %{
                ingress_token: ^token,
                ingress_port: 62_001,
                ingress_panel: true,
                watchdog: true,
                boot: "manual",
                auto_update: true,
                protected: false
              }} = State.get("core_mosquitto", s2)
    end

    test "an old persisted file without the new fields loads with defaults + a generated token",
         %{
           config: c,
           path: path
         } do
      File.mkdir_p!(Path.dirname(path))

      on_disk = %{
        "version" => 1,
        "addons" => %{
          "core_mosquitto" => %{
            "config" => Vagus.Addon.Config.to_persistable(c),
            "state" => "started",
            "user_options" => %{"greeting" => "hi"}
          }
        }
      }

      File.write!(path, Jason.encode!(on_disk))

      s = start_persisted(path)

      assert {:ok,
              %{
                user_options: %{"greeting" => "hi"},
                ingress_token: token,
                ingress_port: nil,
                ingress_panel: false,
                watchdog: false,
                boot: nil,
                auto_update: nil,
                protected: true
              }} = State.get("core_mosquitto", s)

      assert is_binary(token)
    end

    test "a hand-edited protected field that isn't a boolean falls back to true, not false", %{
      config: c,
      path: path
    } do
      # The opposite direction from every other tolerant decoder here: garbage
      # must fail *closed*, since this field is what gates `full_access`.
      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "addons" => %{
            "core_mosquitto" => %{
              "config" => Vagus.Addon.Config.to_persistable(c),
              "state" => "started",
              "protected" => "false"
            }
          }
        })
      )

      assert {:ok, %{protected: true}} = State.get("core_mosquitto", start_persisted(path))
    end

    test "a hand-edited file with garbage boot/auto_update values falls back to nil for both",
         %{config: c, path: path} do
      File.mkdir_p!(Path.dirname(path))

      on_disk = %{
        "version" => 1,
        "addons" => %{
          "core_mosquitto" => %{
            "config" => Vagus.Addon.Config.to_persistable(c),
            "state" => "started",
            "user_options" => %{},
            "boot" => "manual_only",
            "auto_update" => "yes"
          }
        }
      }

      File.write!(path, Jason.encode!(on_disk))

      s = start_persisted(path)
      assert {:ok, %{boot: nil, auto_update: nil}} = State.get("core_mosquitto", s)
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

    # A state file written before `vagus` became a reserved slug. `Config.parse/1`
    # now rejects it, which `decode_entry/2` already treats as a corrupt entry —
    # so it is skipped with a warning and the rest of the file still loads,
    # rather than bricking the boot.
    test "a persisted entry for the reserved 'vagus' slug is dropped, and the rest still loads",
         %{config: c, path: path} do
      File.mkdir_p!(Path.dirname(path))

      on_disk = %{
        "version" => 1,
        "addons" => %{
          "vagus" => %{
            "config" => %{
              "name" => "Impostor",
              "version" => "1.0.0",
              "slug" => "vagus",
              "description" => "installed before the slug was reserved",
              "arch" => ["aarch64"]
            },
            "state" => "started"
          },
          "core_mosquitto" => %{
            "config" => Config.to_persistable(c),
            "state" => "started"
          }
        }
      }

      File.write!(path, Jason.encode!(on_disk))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          s = start_persisted(path)

          assert State.list(s) |> Enum.map(& &1.config.slug) == ["core_mosquitto"]
          assert :error = State.get("vagus", s)
        end)

      assert log =~ "dropping invalid/mismatched entry"
      assert log =~ "vagus"
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

  describe "the installed version (P2-A P2)" do
    # `entry.config.version` IS the installed version — there is no separate
    # persisted field. These tests cover the `State.put/3` level: writing back
    # a config that was read out of `State` keeps the version, and only a
    # genuinely different config moves it.
    #
    # They are NOT the guard against the invariant breaking. They drive
    # `State.put/3` by hand, so they would pass unchanged if `Manager`,
    # `BootStarter` or `Watchdog` started sourcing config from `Store`
    # instead of `State` — verified by sabotaging `do_start_slug/2`, which
    # these three did not notice. The real guard is
    # `addon_lifecycle_router_test.exs`'s "a real stop/start never adopts the
    # store's version", which drives the actual lifecycle routes and does
    # fail under that sabotage.
    test "a lifecycle transition never moves it", %{config: c, s: s} do
      :ok = State.put(c, :started, server: s)
      assert {:ok, %{config: %{version: "7.1.0"}}} = State.get(c.slug, s)

      # The shape of a stop: read the persisted config back, write it with a
      # new lifecycle state. Exactly what Manager/BootStarter/Watchdog do.
      {:ok, %{config: persisted}} = State.get(c.slug, s)
      :ok = State.put(persisted, :stopped, server: s)
      assert {:ok, %{config: %{version: "7.1.0"}, state: :stopped}} = State.get(c.slug, s)

      {:ok, %{config: persisted2}} = State.get(c.slug, s)
      :ok = State.put(persisted2, :started, server: s)
      assert {:ok, %{config: %{version: "7.1.0"}, state: :started}} = State.get(c.slug, s)
    end

    test "an install/update of a new config does move it", %{config: c, s: s} do
      # The other half of the invariant: writing a genuinely different config
      # (what install and, later, update do) is the only thing that changes
      # the reported version.
      :ok = State.put(c, :started, server: s)
      :ok = State.put(%{c | version: "7.2.0"}, :started, server: s)

      assert {:ok, %{config: %{version: "7.2.0"}}} = State.get(c.slug, s)
    end

    test "it survives a round-trip through disk", %{config: c} do
      path =
        Path.join(
          System.tmp_dir!(),
          "vagus_state_version_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)

      first = start_supervised!({State, name: nil, persist_path: path}, id: :first)
      :ok = State.put(c, :started, server: first)
      :ok = stop_supervised!(:first)

      revived = start_supervised!({State, name: nil, persist_path: path}, id: :revived)
      assert {:ok, %{config: %{version: "7.1.0"}}} = State.get(c.slug, revived)
    end
  end
end
