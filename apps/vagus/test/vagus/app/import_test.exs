defmodule Vagus.App.ImportTest do
  # Points the global app tree at a fresh apps directory for the test.
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  import ExUnit.CaptureLog

  alias Vagus.Addon.Config
  alias Vagus.API.{Router, Token}
  alias Vagus.App.File, as: AppFile
  alias Vagus.App.Instances

  @fixture Path.expand("../../fixtures/addons-0.9.0.json", __DIR__)
  @opts Router.init([])

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    prev = Application.fetch_env!(:vagus, :app_files_dir)
    dir = Path.join(tmp, "apps")
    Application.put_env(:vagus, :app_files_dir, dir)
    legacy = Path.join(tmp, "addons.json")
    File.cp!(@fixture, legacy)

    on_exit(fn ->
      for slug <- AppFile.saved(dir), do: Instances.stop(slug)
      Application.put_env(:vagus, :app_files_dir, prev)
    end)

    %{legacy: legacy, legacy_entries: Jason.decode!(File.read!(@fixture))["addons"]}
  end

  defp info(slug) do
    conn =
      conn(:get, "/addons/#{slug}/info")
      |> put_req_header("authorization", "Bearer #{Token.get()}")
      |> Router.call(@opts)

    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)["data"]
  end

  # Every field the 0.9.0 reader kept from each entry, checked against what
  # the process answers and what the router renders from it.
  test "a 0.9.0 addons.json imported to processes answers every field as before", %{
    legacy: legacy,
    legacy_entries: entries
  } do
    capture_log(fn -> assert {:ok, 3} = AppFile.import_once(AppFile.dir(), legacy) end)
    slugs = AppFile.saved()
    assert Enum.sort(slugs) == ["core_mqtt", "core_ssh", "esphome_esphome"]

    for slug <- slugs do
      raw = Map.fetch!(entries, slug)
      {:ok, config} = Config.parse(raw["config"])
      wanted = String.to_existing_atom(raw["state"])
      {:ok, pid} = Instances.ensure(slug)

      # A process knows a container runs only once the engine says so.
      if wanted == :started do
        assert {:ok, %{state: :stopped}} = Vagus.App.info(slug)
        send(pid, {:docker_event, %{action: "start", id: "c-" <> slug, name: "addon_" <> slug}})
      end

      {:ok, new} = Vagus.App.info(slug)

      assert new == %{
               config: config,
               state: wanted,
               wanted: wanted,
               user_options: raw["user_options"],
               ports: raw["network"],
               ingress_token: raw["ingress_token"],
               ingress_port: raw["ingress_port"],
               ingress_panel: raw["ingress_panel"],
               watchdog: raw["watchdog"],
               boot: raw["boot"],
               auto_update: raw["auto_update"],
               protected: raw["protected"]
             },
             slug

      body = info(slug)
      assert body["state"] == raw["state"]
      assert body["version"] == config.version
      assert body["network"] |> Map.reject(fn {_k, v} -> is_nil(v) end) == raw["network"]
      assert body["ingress_url"] == ingress_url(config, raw["ingress_token"])

      for key <- ~w(ingress_panel watchdog protected),
          do: assert(body[key] == raw[key], "#{slug} #{key}")
    end
  end

  defp ingress_url(%{ingress: true}, token), do: "/api/hassio_ingress/#{token}/"
  defp ingress_url(_config, _token), do: nil
end
