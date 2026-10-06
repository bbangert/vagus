defmodule Vagus.ServicesTest do
  use ExUnit.Case, async: true

  alias Vagus.Services

  setup do
    svc = start_supervised!({Services, name: :"svc_#{System.unique_integer([:positive])}"})
    %{svc: svc}
  end

  @mqtt %{"host" => "core-mosquitto", "port" => 1883, "ssl" => false, "protocol" => "3.1.1"}

  test "set then get returns the data with the provider under the addon key", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:ok, data} = Services.get("mqtt", svc)
    assert data["host"] == "core-mosquitto"
    assert data["port"] == 1883
    assert data["addon"] == "core_mosquitto"
  end

  test "get an unprovided service is :error", %{svc: svc} do
    assert :error = Services.get("mqtt", svc)
  end

  test "double set is rejected (already provided)", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:error, :already_provided} = Services.set("mqtt", @mqtt, "other", svc)
  end

  test "only the provider may delete; delete is idempotent", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:error, :not_provider} = Services.delete("mqtt", "intruder", svc)
    assert :ok = Services.delete("mqtt", "core_mosquitto", svc)
    assert :error = Services.get("mqtt", svc)
    assert :ok = Services.delete("mqtt", "anyone", svc)
  end

  test "list reflects availability + providers", %{svc: svc} do
    assert [%{slug: "mqtt", available: false, providers: []}] = Services.list(svc)
    Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert [%{slug: "mqtt", available: true, providers: ["core_mosquitto"]}] = Services.list(svc)
  end

  test "delete_by_slug purges every service the slug provides, leaving others intact", %{
    svc: svc
  } do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:ok, ["mqtt"]} = Services.delete_by_slug("core_mosquitto", svc)
    assert :error = Services.get("mqtt", svc)
  end

  test "delete_by_slug for a slug that provides nothing is a no-op", %{svc: svc} do
    assert :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
    assert {:ok, []} = Services.delete_by_slug("someone_else", svc)
    assert {:ok, _data} = Services.get("mqtt", svc)
  end

  describe "format_status/1 (a service's config carries its password)" do
    @password "pw-must-not-print"

    test ":sys.get_status/1 shows the service and its provider, never the config", %{svc: svc} do
      :ok = Services.set("mqtt", Map.put(@mqtt, "password", @password), "shown_slug", svc)

      status = inspect(:sys.get_status(svc), limit: :infinity, printable_limit: :infinity)
      refute status =~ @password
      assert status =~ "shown_slug"
    end

    test "a crash report's last message carries no config" do
      message = {:set, "mqtt", %{"password" => @password}, "shown_slug"}
      formatted = Services.format_status(%{message: message, reason: :boom})

      assert formatted == %{message: {:set, "mqtt", :redacted, "shown_slug"}, reason: :boom}

      assert %{message: {:delete_by_slug, "shown_slug"}} =
               Services.format_status(%{message: {:delete_by_slug, "shown_slug"}})
    end
  end

  describe "checkpoint" do
    setup do
      dir = Path.join(System.tmp_dir!(), "vagus-svc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "services.term")
      %{path: path, svc: start_checkpointed(path)}
    end

    defp start_checkpointed(path),
      do: start_supervised!({Services, name: nil, path: path}, id: :checkpointed)

    defp restart_checkpointed(path) do
      :ok = stop_supervised!(:checkpointed)
      start_checkpointed(path)
    end

    test "a provided service is still provided after a restart on the same path", %{
      svc: svc,
      path: path
    } do
      :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)

      svc = restart_checkpointed(path)

      assert {:ok, %{"host" => "core-mosquitto", "addon" => "core_mosquitto"}} =
               Services.get("mqtt", svc)

      assert {:error, :already_provided} = Services.set("mqtt", @mqtt, "other", svc)
    end

    test "a deleted service stays gone after a restart", %{svc: svc, path: path} do
      :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
      :ok = Services.delete("mqtt", "core_mosquitto", svc)

      svc = restart_checkpointed(path)

      assert :error = Services.get("mqtt", svc)
    end

    test "a slug's purged services stay gone after a restart", %{svc: svc, path: path} do
      :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)
      {:ok, ["mqtt"]} = Services.delete_by_slug("core_mosquitto", svc)

      svc = restart_checkpointed(path)

      assert :error = Services.get("mqtt", svc)
    end

    # A save can fail, and a failed save drops the checkpoint.
    test "a delete_by_slug that removes nothing does not save", %{svc: svc, path: path} do
      :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)

      File.mkdir_p!(path <> ".tmp")
      assert {:ok, []} = Services.delete_by_slug("someone_else", svc)

      svc = restart_checkpointed(path)

      assert {:ok, %{"addon" => "core_mosquitto"}} = Services.get("mqtt", svc)
    end

    # A privately-named instance falling back to the default path would read
    # and overwrite the application Services' checkpoint.
    test "a privately-named instance without a :path keeps nothing across a restart" do
      name = :"svc_#{System.unique_integer([:positive])}"

      svc = start_supervised!({Services, name: name}, id: :pathless)
      :ok = Services.set("mqtt", @mqtt, "memory_only", svc)

      :ok = stop_supervised!(:pathless)
      svc = start_supervised!({Services, name: name}, id: :pathless)

      assert :error = Services.get("mqtt", svc)
    end

    test "an unusable file starts it empty and working, naming only the path", %{
      path: path
    } do
      stale = %{data: %{"password" => "pw-stale"}, slug: "stale"}

      for content <- [
            "not a term",
            :erlang.term_to_binary(:nope),
            :erlang.term_to_binary(%{"mqtt" => :nope}),
            :erlang.term_to_binary(%{"mqtt" => %{stale | data: "pw-stale"}}),
            :erlang.term_to_binary(%{"mqtt" => %{stale | slug: nil}}),
            :erlang.term_to_binary(%{"mqtt" => stale, mqtt: stale}),
            :erlang.term_to_binary(%URI{}),
            :erlang.term_to_binary(MapSet.new())
          ] do
        :ok = stop_supervised!(:checkpointed)
        File.write!(path, content)
        {svc, log} = ExUnit.CaptureLog.with_log(fn -> start_checkpointed(path) end)

        assert log =~ "run state #{path} unusable"
        refute log =~ "pw-stale"
        assert :error = Services.get("mqtt", svc)
        assert :ok = Services.set("mqtt", @mqtt, "fresh", svc)
        assert {:ok, %{"addon" => "fresh"}} = Services.get("mqtt", svc)
        assert [%{available: true, providers: ["fresh"]}] = Services.list(svc)
      end
    end

    # An older checkpoint surviving a failed save would bring a removed
    # provider's credentials back on the next restart.
    @tag :capture_log
    test "a failed save leaves the next start empty, not on the older checkpoint", %{
      svc: svc,
      path: path
    } do
      :ok = Services.set("mqtt", @mqtt, "core_mosquitto", svc)

      # The save writes `path <> ".tmp"` first; a directory there fails it.
      File.mkdir_p!(path <> ".tmp")
      assert :ok = Services.delete("mqtt", "core_mosquitto", svc)
      assert :ok = Services.set("mqtt", @mqtt, "successor", svc)
      assert {:ok, %{"addon" => "successor"}} = Services.get("mqtt", svc)

      svc = restart_checkpointed(path)

      assert :error = Services.get("mqtt", svc)
    end
  end
end
