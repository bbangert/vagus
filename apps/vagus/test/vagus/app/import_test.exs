defmodule Vagus.App.ImportTest do
  # Points the global app tree at a fresh apps directory for the test.
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  import ExUnit.CaptureLog

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

  # The old reader is `Vagus.Addon.State` over the same file: whatever the
  # router renders from its entry, it now renders from the process's answer.
  test "a 0.9.0 addons.json imported to processes answers every field as before", %{
    legacy: legacy
  } do
    old_state = start_supervised!({Vagus.Addon.State, name: nil, persist_path: legacy})
    capture_log(fn -> assert {:ok, 3} = AppFile.import_once(AppFile.dir(), legacy) end)
    slugs = AppFile.saved()
    assert Enum.sort(slugs) == ["core_mqtt", "core_ssh", "esphome_esphome"]

    for slug <- slugs do
      {:ok, old} = Vagus.Addon.State.get(slug, old_state)
      {:ok, pid} = Instances.ensure(slug)

      # A process knows a container runs only once the engine says so.
      if old.state == :started do
        assert {:ok, %{state: :stopped}} = Vagus.App.info(slug)
        send(pid, {:docker_event, %{action: "start", id: "c-" <> slug, name: "addon_" <> slug}})
      end

      {:ok, new} = Vagus.App.info(slug)
      assert Map.delete(new, :wanted) == old, slug
      assert new.wanted == old.state

      body = info(slug)
      assert body["state"] == Atom.to_string(old.state)
      assert body["version"] == old.config.version
      assert body["network"] |> Map.reject(fn {_k, v} -> is_nil(v) end) == old.ports
      assert body["ingress_url"] == ingress_url(old)

      for key <- ~w(ingress_panel watchdog protected)a,
          do: assert(body[Atom.to_string(key)] == Map.fetch!(old, key), "#{slug} #{key}")
    end
  end

  defp ingress_url(%{config: %{ingress: true}, ingress_token: token}),
    do: "/api/hassio_ingress/#{token}/"

  defp ingress_url(_entry), do: nil
end
