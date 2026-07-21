defmodule Vagus.Ingress.PanelsTest do
  @moduledoc """
  IW-P2-T3: `Vagus.Ingress.Panels` — the §B4.1 `list/1` shape and the §B4.2
  push-to-Core (`update_hass_panel/2`).

  `update_hass_panel/2`'s push goes through `Vagus.Core.Client.request/3`, so
  the push tests stand up a real `Vagus.Core.Client` + `Vagus.Core.TokenStore`
  against a tiny fake-Core `Bandit` server (mirroring
  `Vagus.Core.ClientTest`'s `FakeCore` fixture) rather than mocking the
  client away — this is the actual seam the router/manager hooks go through
  in production. All push assertions use `sync: true` so the push happens
  inline before the assertion runs, instead of racing a detached `Task`.
  """
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, State}
  alias Vagus.Core.{Client, TokenStore}
  alias Vagus.Ingress.Panels

  # A tiny Plug standing in for Core's `/api/hassio_push/panel/{slug}` (and
  # `/auth/token`, which `Client` needs first) — same shape as
  # `Vagus.Core.ClientTest.FakeCore`. Method + slug of each push are reported
  # back to the test process via message so assertions can be exact about
  # which verb was used.
  defmodule FakeCore do
    @moduledoc false
    use Plug.Router

    plug(Plug.Parsers, parsers: [:urlencoded, :json], json_decoder: Jason, pass: ["*/*"])
    plug(:match)
    plug(:dispatch)

    post "/auth/token" do
      send_json(conn, 200, %{
        "access_token" => "access-#{System.unique_integer([:positive])}",
        "expires_in" => 3600,
        "token_type" => "Bearer"
      })
    end

    match "/api/hassio_push/panel/:slug" do
      report(conn.method, slug)
      send_json(conn, 200, %{})
    end

    match _ do
      send_json(conn, 404, %{"error" => "not_found"})
    end

    defp report(method, slug) do
      case :persistent_term.get({__MODULE__, :reporter}, nil) do
        nil -> :ok
        pid -> send(pid, {:panel_push, method, slug})
      end
    end

    defp send_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  defp start_fake_core(reporter) do
    :persistent_term.put({FakeCore, :reporter}, reporter)
    bandit = start_supervised!({Bandit, plug: FakeCore, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    "http://127.0.0.1:#{port}"
  end

  defp start_client(base_url) do
    finch = :"finch_#{System.unique_integer([:positive])}"
    start_supervised!({Finch, name: finch})

    token_store = :"token_store_#{System.unique_integer([:positive])}"

    path =
      Path.join(System.tmp_dir!(), "panels_test_ts_#{System.unique_integer([:positive])}.json")

    start_supervised!({TokenStore, name: token_store, path: path})
    :ok = TokenStore.put_options(%{"refresh_token" => "panels-test-refresh"}, token_store)
    on_exit(fn -> File.rm(path) end)

    client = :"client_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Client, name: client, core_base_url: base_url, finch_name: finch, token_store: token_store}
    )

    client
  end

  defp start_state(name) do
    start_supervised!({State, name: name, persist_path: nil})
    name
  end

  defp ingress_config(slug, opts \\ []) do
    {:ok, config} =
      Config.parse(%{
        "name" => Keyword.get(opts, :name, "ESPHome"),
        "version" => "1",
        "slug" => slug,
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "homeassistant/{arch}-addon-esphome",
        "ingress" => Keyword.get(opts, :ingress, true),
        "panel_title" => Keyword.get(opts, :panel_title),
        "panel_icon" => Keyword.get(opts, :panel_icon, "mdi:puzzle"),
        "panel_admin" => Keyword.get(opts, :panel_admin, true)
      })

    config
  end

  describe "list/1 (§B4.1)" do
    test "one entry per ingress-capable add-on; non-ingress absent; enable reflects the toggle" do
      state = start_state(:"state_#{System.unique_integer([:positive])}")

      enabled =
        ingress_config("core_esphome", panel_title: "ESPHome Dashboard", panel_icon: "mdi:chip")

      :ok = State.put(enabled, :started, server: state)
      :ok = State.put_setting("core_esphome", :ingress_panel, true, state)

      disabled = ingress_config("core_other", panel_title: nil)
      :ok = State.put(disabled, :started, server: state)
      # ingress_panel defaults to false — left untouched.

      {:ok, non_ingress} =
        Config.parse(%{
          "name" => "Plain",
          "version" => "1",
          "slug" => "plain_addon",
          "description" => "d",
          "arch" => ["amd64"],
          "image" => "x/y",
          "ingress" => false
        })

      :ok = State.put(non_ingress, :started, server: state)

      panels = Panels.list(state)

      assert Map.keys(panels) |> Enum.sort() == ["core_esphome", "core_other"]

      assert panels["core_esphome"] == %{
               "title" => "ESPHome Dashboard",
               "icon" => "mdi:chip",
               "admin" => true,
               "enable" => true
             }

      # panel_title nil falls back to config.name; enable false but present.
      assert panels["core_other"] == %{
               "title" => "ESPHome",
               "icon" => "mdi:puzzle",
               "admin" => true,
               "enable" => false
             }
    end

    test "empty when no add-ons are installed" do
      state = start_state(:"state_#{System.unique_integer([:positive])}")
      assert Panels.list(state) == %{}
    end
  end

  describe "update_hass_panel/2 (§B4.2, sync: true)" do
    test "POSTs when ingress_panel is true" do
      base_url = start_fake_core(self())
      client = start_client(base_url)
      state = start_state(:"state_#{System.unique_integer([:positive])}")

      config = ingress_config("core_esphome")
      :ok = State.put(config, :started, server: state)
      :ok = State.put_setting("core_esphome", :ingress_panel, true, state)

      assert :ok =
               Panels.update_hass_panel("core_esphome", state: state, client: client, sync: true)

      assert_received {:panel_push, "POST", "core_esphome"}
    end

    test "DELETEs when ingress_panel is false" do
      base_url = start_fake_core(self())
      client = start_client(base_url)
      state = start_state(:"state_#{System.unique_integer([:positive])}")

      config = ingress_config("core_esphome")
      :ok = State.put(config, :started, server: state)

      assert :ok =
               Panels.update_hass_panel("core_esphome", state: state, client: client, sync: true)

      assert_received {:panel_push, "DELETE", "core_esphome"}
    end

    test "DELETEs for an unknown/untracked slug (uninstall's after-purge call)" do
      base_url = start_fake_core(self())
      client = start_client(base_url)
      state = start_state(:"state_#{System.unique_integer([:positive])}")

      assert :ok =
               Panels.update_hass_panel("never_installed",
                 state: state,
                 client: client,
                 sync: true
               )

      assert_received {:panel_push, "DELETE", "never_installed"}
    end

    test "an unreachable Core logs a warning and never raises" do
      state = start_state(:"state_#{System.unique_integer([:positive])}")
      config = ingress_config("core_esphome")
      :ok = State.put(config, :started, server: state)
      :ok = State.put_setting("core_esphome", :ingress_panel, true, state)

      client = :"unreachable_client_#{System.unique_integer([:positive])}"
      token_store = :"unreachable_token_store_#{System.unique_integer([:positive])}"
      finch = :"unreachable_finch_#{System.unique_integer([:positive])}"

      path =
        Path.join(
          System.tmp_dir!(),
          "panels_unreachable_#{System.unique_integer([:positive])}.json"
        )

      start_supervised!({Finch, name: finch})
      start_supervised!({TokenStore, name: token_store, path: path})
      :ok = TokenStore.put_options(%{"refresh_token" => "whatever"}, token_store)
      on_exit(fn -> File.rm(path) end)

      start_supervised!(
        {Client,
         name: client,
         core_base_url: "http://127.0.0.1:1",
         finch_name: finch,
         token_store: token_store}
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Panels.update_hass_panel("core_esphome",
                     state: state,
                     client: client,
                     sync: true
                   )
        end)

      assert log =~ "panel push"
    end

    # `Vagus.Core.Client` has no `:core_client_enabled`-style test gate (unlike
    # `Vagus.Ingress`/`Vagus.DNS`/etc — see `Vagus.Application`'s
    # `ingress_children/0` comment), so the app's default-named instance is
    # always running in this suite and the "skip, no client at all" branch of
    # `client_available?/1` can't be exercised in-process here. What's
    # testable instead: omitting `:client` entirely (falling back to that
    # real default-named process, whose `Vagus.Core.TokenStore` has no
    # refresh token configured in `config/test.exs`) still never crashes —
    # it hits the same `{:error, _}` warning path as the unreachable-Core
    # test above, just via `:no_refresh_token` instead of a connection error.
    test "no :client opt given (falls back to the default-named Client): never crashes" do
      state = start_state(:"state_#{System.unique_integer([:positive])}")
      config = ingress_config("core_esphome")
      :ok = State.put(config, :started, server: state)
      :ok = State.put_setting("core_esphome", :ingress_panel, true, state)

      assert Process.whereis(Client)
      assert :ok = Panels.update_hass_panel("core_esphome", state: state, sync: true)
    end
  end
end
