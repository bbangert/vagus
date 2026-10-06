defmodule Vagus.Addon.RegistryTest do
  use ExUnit.Case, async: true

  alias Vagus.Addon.{Config, Registry}

  setup do
    reg = start_supervised!({Registry, name: :"reg_#{System.unique_integer([:positive])}"})
    %{reg: reg}
  end

  test "register + lookup", %{reg: reg} do
    id = %{
      slug: "core_mosquitto",
      services_role: %{"mqtt" => "provide"},
      auth_api: true,
      discovery: ["mqtt"]
    }

    assert :ok = Registry.register("tok-a", id, reg)
    assert {:ok, ^id} = Registry.identity_for_token("tok-a", reg)
    assert :error = Registry.identity_for_token("unknown", reg)
  end

  test "re-register for a slug drops the old token", %{reg: reg} do
    id = %{slug: "x", services_role: %{}, auth_api: false, discovery: []}
    Registry.register("old", id, reg)
    Registry.register("new", id, reg)
    assert :error = Registry.identity_for_token("old", reg)
    assert {:ok, ^id} = Registry.identity_for_token("new", reg)
  end

  test "unregister_slug removes the token", %{reg: reg} do
    id = %{slug: "y", services_role: %{}, auth_api: false, discovery: []}
    Registry.register("t", id, reg)
    assert :ok = Registry.unregister_slug("y", reg)
    assert :error = Registry.identity_for_token("t", reg)
  end

  test "identity_from_config derives grants from config.yaml fields" do
    {:ok, config} =
      Config.parse(%{
        "name" => "M",
        "version" => "1",
        "slug" => "core_mosquitto",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "services" => ["mqtt:provide"],
        "auth_api" => true,
        "discovery" => ["mqtt"],
        "hassio_api" => true,
        "hassio_role" => "manager",
        "homeassistant_api" => true
      })

    assert Registry.identity_from_config(config) == %{
             slug: "core_mosquitto",
             services_role: %{"mqtt" => "provide"},
             auth_api: true,
             discovery: ["mqtt"],
             hassio_api: true,
             hassio_role: "manager",
             homeassistant_api: true
           }
  end

  # `.claude/plans/vagus-core-api-proxy/plan.md` phase 1: `homeassistant_api`
  # is what the Core-API proxy's `_check_access` equivalent grades a caller
  # with, and it's the same shape of gap `hassio_api`/`hassio_role` were
  # before the 2026-07-29 audit — `Vagus.Addon.Config` parsed it, but
  # `identity_from_config/1` dropped it because nothing consumed it yet.
  test "identity_from_config carries homeassistant_api through" do
    {:ok, config} =
      Config.parse(%{
        "name" => "M",
        "version" => "1",
        "slug" => "core_ha_api",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y",
        "homeassistant_api" => true
      })

    assert %{homeassistant_api: true} = Registry.identity_from_config(config)
  end

  # `hassio_api`/`hassio_role` are what `Vagus.API.Tiers` grades a caller
  # with, and `Vagus.Addon.Config`'s defaults are the closed ones. An add-on
  # that declares neither must arrive here as "no API access, default role" —
  # if this silently became `hassio_api: true`, every installed add-on would
  # regain the manager-tier reach the 2026-07-29 audit found (A1/A2).
  test "identity_from_config defaults an add-on that declares no API access to closed" do
    {:ok, config} =
      Config.parse(%{
        "name" => "M",
        "version" => "1",
        "slug" => "quiet",
        "description" => "d",
        "arch" => ["amd64"],
        "image" => "x/y"
      })

    assert %{hassio_api: false, hassio_role: "default", homeassistant_api: false} =
             Registry.identity_from_config(config)
  end

  describe "format_status/1 (tokens are bearer credentials)" do
    @token "tok-must-not-print"

    test ":sys.get_status/1 shows the slug, never the token", %{reg: reg} do
      id = %{slug: "shown_slug", services_role: %{}, auth_api: false, discovery: []}
      :ok = Registry.register(@token, id, reg)

      status = inspect(:sys.get_status(reg), limit: :infinity, printable_limit: :infinity)
      refute status =~ @token
      assert status =~ "shown_slug"
    end

    test "a crash report's last message carries no token" do
      for message <- [{:register, @token, %{slug: "shown_slug"}}, {:lookup, @token}] do
        formatted = Registry.format_status(%{message: message, reason: :boom})

        refute inspect(formatted, limit: :infinity) =~ @token
        assert formatted.reason == :boom
      end

      assert %{message: {:unregister_slug, "shown_slug"}} =
               Registry.format_status(%{message: {:unregister_slug, "shown_slug"}})
    end
  end

  describe "checkpoint" do
    setup do
      dir = Path.join(System.tmp_dir!(), "vagus-reg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "registry.term")
      %{path: path, reg: start_checkpointed(path)}
    end

    defp start_checkpointed(path),
      do: start_supervised!({Registry, name: nil, path: path}, id: :checkpointed)

    defp restart_checkpointed(path) do
      :ok = stop_supervised!(:checkpointed)
      start_checkpointed(path)
    end

    defp identity(slug), do: %{slug: slug, services_role: %{}, auth_api: false, discovery: []}

    test "a registered token resolves after a restart on the same path", %{reg: reg, path: path} do
      :ok = Registry.register("tok-kept", identity("kept"), reg)

      reg = restart_checkpointed(path)

      assert {:ok, %{slug: "kept"}} = Registry.identity_for_token("tok-kept", reg)
    end

    test "a replaced token stays replaced after a restart", %{reg: reg, path: path} do
      :ok = Registry.register("tok-old", identity("rotated"), reg)
      :ok = Registry.register("tok-new", identity("rotated"), reg)

      reg = restart_checkpointed(path)

      assert :error = Registry.identity_for_token("tok-old", reg)
      assert {:ok, %{slug: "rotated"}} = Registry.identity_for_token("tok-new", reg)
    end

    test "an unregistered slug's token stays gone after a restart", %{reg: reg, path: path} do
      :ok = Registry.register("tok-gone", identity("gone"), reg)
      :ok = Registry.register("tok-other", identity("other"), reg)
      :ok = Registry.unregister_slug("gone", reg)

      reg = restart_checkpointed(path)

      assert :error = Registry.identity_for_token("tok-gone", reg)
      assert {:ok, %{slug: "other"}} = Registry.identity_for_token("tok-other", reg)
    end

    # A privately-named instance falling back to the default path would read
    # and overwrite the application Registry's checkpoint.
    test "a privately-named instance without a :path keeps nothing across a restart" do
      name = :"reg_#{System.unique_integer([:positive])}"
      token = "tok-memory-only-#{System.unique_integer([:positive])}"

      reg = start_supervised!({Registry, name: name}, id: :pathless)
      :ok = Registry.register(token, identity("memory_only"), reg)
      assert {:ok, _identity} = Registry.identity_for_token(token, reg)

      :ok = stop_supervised!(:pathless)
      reg = start_supervised!({Registry, name: name}, id: :pathless)

      assert :error = Registry.identity_for_token(token, reg)
    end

    test "an unusable file starts the registry empty and working, naming only the path", %{
      path: path
    } do
      stale = %{"tok-stale" => identity("stale")}

      for content <- [
            "not a term",
            :erlang.term_to_binary(:nope),
            :erlang.term_to_binary(%{by_token: 1}),
            :erlang.term_to_binary(%{by_token: stale}),
            :erlang.term_to_binary(%{by_token: stale, token_by_slug: :nope})
          ] do
        :ok = stop_supervised!(:checkpointed)
        File.write!(path, content)
        {reg, log} = ExUnit.CaptureLog.with_log(fn -> start_checkpointed(path) end)

        assert log =~ "run state #{path} unusable"
        refute log =~ "tok-stale"
        assert :error = Registry.identity_for_token("tok-stale", reg)
        assert :ok = Registry.register("tok-fresh", identity("stale"), reg)
        assert {:ok, %{slug: "stale"}} = Registry.identity_for_token("tok-fresh", reg)
      end
    end

    # An older checkpoint surviving a failed save would bring a revoked token
    # back on the next restart.
    @tag :capture_log
    test "a failed save leaves the next start empty, not on the older checkpoint", %{
      reg: reg,
      path: path
    } do
      :ok = Registry.register("tok-revoked", identity("revoked"), reg)
      :ok = Registry.register("tok-bystander", identity("bystander"), reg)

      # The save writes `path <> ".tmp"` first; a directory there fails it.
      File.mkdir_p!(path <> ".tmp")
      assert :ok = Registry.unregister_slug("revoked", reg)
      assert {:ok, _identity} = Registry.identity_for_token("tok-bystander", reg)

      reg = restart_checkpointed(path)

      assert :error = Registry.identity_for_token("tok-revoked", reg)
      assert :error = Registry.identity_for_token("tok-bystander", reg)
    end
  end
end
