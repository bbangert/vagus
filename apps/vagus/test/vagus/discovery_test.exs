defmodule Vagus.DiscoveryTest do
  @moduledoc "P4-T2: the discovery registry state machine."
  use ExUnit.Case, async: true

  alias Vagus.Discovery

  setup do
    {:ok, pid} = Discovery.start_link(name: nil)
    %{d: pid}
  end

  test "add mints a 32-char lowercase-hex uuid and stores the message", %{d: d} do
    {:ok, msg, :new} = Discovery.add("core_mosquitto", "mqtt", %{"host" => "core-mosquitto"}, d)
    assert msg.addon == "core_mosquitto"
    assert msg.service == "mqtt"
    assert msg.config == %{"host" => "core-mosquitto"}
    assert msg.uuid =~ ~r/\A[0-9a-f]{32}\z/
    assert {:ok, ^msg} = Discovery.get(msg.uuid, d)
  end

  test "distinct (addon, service) pairs each get their own uuid", %{d: d} do
    {:ok, a, :new} = Discovery.add("s", "mqtt", %{}, d)
    {:ok, b, :new} = Discovery.add("other", "mqtt", %{}, d)
    {:ok, c, :new} = Discovery.add("s", "other_service", %{}, d)
    refute a.uuid == b.uuid
    refute a.uuid == c.uuid
    assert length(Discovery.list(d)) == 3
  end

  test "a repeat add for the same (addon, service) with identical config is a no-op :existing",
       %{d: d} do
    {:ok, first, :new} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)
    {:ok, second, :existing} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)

    assert second == first
    assert length(Discovery.list(d)) == 1
  end

  test "a repeat add for the same (addon, service) with a changed config keeps the uuid and reports :updated",
       %{d: d} do
    {:ok, first, :new} = Discovery.add("s", "mqtt", %{"host" => "h1"}, d)
    {:ok, second, :updated} = Discovery.add("s", "mqtt", %{"host" => "h2"}, d)

    assert second.uuid == first.uuid
    assert second.config == %{"host" => "h2"}
    assert length(Discovery.list(d)) == 1
    assert {:ok, ^second} = Discovery.get(first.uuid, d)
  end

  test "get on an unknown uuid is :error", %{d: d} do
    assert :error = Discovery.get("deadbeef", d)
  end

  test "delete is owner-only", %{d: d} do
    {:ok, msg, :new} = Discovery.add("owner", "mqtt", %{}, d)
    assert {:error, :not_owner} = Discovery.delete(msg.uuid, "someone_else", d)
    assert {:ok, ^msg} = Discovery.get(msg.uuid, d)

    assert {:ok, ^msg} = Discovery.delete(msg.uuid, "owner", d)
    assert :error = Discovery.get(msg.uuid, d)
  end

  test "delete of an unknown uuid is :not_found", %{d: d} do
    assert {:error, :not_found} = Discovery.delete("nope", "owner", d)
  end

  test "delete_by_slug removes only that add-on's messages", %{d: d} do
    {:ok, a, :new} = Discovery.add("a", "mqtt", %{}, d)
    {:ok, _b, :new} = Discovery.add("b", "mqtt", %{}, d)
    {:ok, removed} = Discovery.delete_by_slug("a", d)
    assert removed == [a]
    assert [%{addon: "b"}] = Discovery.list(d)
  end

  describe "format_status/1 (a message's config can carry a password)" do
    @password "pw-must-not-print"

    test ":sys.get_status/1 shows the uuid, add-on and service, never the config", %{d: d} do
      {:ok, %{uuid: uuid}, :new} =
        Discovery.add("shown_slug", "shown_service", %{"password" => @password}, d)

      status = inspect(:sys.get_status(d), limit: :infinity, printable_limit: :infinity)
      refute status =~ @password
      assert status =~ uuid
      assert status =~ "shown_slug"
      assert status =~ "shown_service"
    end

    test "a crash report's last message carries no config" do
      message = {:add, "shown_slug", "mqtt", %{"password" => @password}}
      formatted = Discovery.format_status(%{message: message, reason: :boom})

      assert formatted == %{message: {:add, "shown_slug", "mqtt", :redacted}, reason: :boom}

      assert %{message: {:delete_by_slug, "shown_slug"}} =
               Discovery.format_status(%{message: {:delete_by_slug, "shown_slug"}})
    end
  end

  describe "checkpoint" do
    setup do
      dir = Path.join(System.tmp_dir!(), "vagus-disc-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "discovery.term")
      %{path: path, d: start_checkpointed(path)}
    end

    defp start_checkpointed(path),
      do: start_supervised!({Discovery, name: nil, path: path}, id: :checkpointed)

    defp restart_checkpointed(path) do
      :ok = stop_supervised!(:checkpointed)
      start_checkpointed(path)
    end

    test "a message is still there after a restart on the same path", %{d: d, path: path} do
      {:ok, msg, :new} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)

      d = restart_checkpointed(path)

      assert {:ok, ^msg} = Discovery.get(msg.uuid, d)
      assert [^msg] = Discovery.list(d)
    end

    # A fresh uuid here would give Core a second config flow for the add-on.
    test "a repeat add after a restart is :existing under the same uuid", %{d: d, path: path} do
      {:ok, msg, :new} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)

      d = restart_checkpointed(path)

      assert {:ok, ^msg, :existing} = Discovery.add("s", "mqtt", %{"host" => "h"}, d)
    end

    test "a changed config after a restart is :updated under the same uuid, and is kept", %{
      d: d,
      path: path
    } do
      {:ok, %{uuid: uuid}, :new} = Discovery.add("s", "mqtt", %{"host" => "h1"}, d)

      d = restart_checkpointed(path)

      assert {:ok, %{uuid: ^uuid} = updated, :updated} =
               Discovery.add("s", "mqtt", %{"host" => "h2"}, d)

      d = restart_checkpointed(path)

      assert {:ok, ^updated} = Discovery.get(uuid, d)
    end

    test "a deleted message stays gone after a restart", %{d: d, path: path} do
      {:ok, gone, :new} = Discovery.add("gone", "mqtt", %{}, d)
      {:ok, other, :new} = Discovery.add("other", "mqtt", %{}, d)
      {:ok, ^gone} = Discovery.delete(gone.uuid, "gone", d)

      d = restart_checkpointed(path)

      assert [^other] = Discovery.list(d)
    end

    test "a slug's purged messages stay gone after a restart", %{d: d, path: path} do
      {:ok, gone, :new} = Discovery.add("gone", "mqtt", %{}, d)
      {:ok, other, :new} = Discovery.add("other", "mqtt", %{}, d)
      {:ok, [^gone]} = Discovery.delete_by_slug("gone", d)

      d = restart_checkpointed(path)

      assert [^other] = Discovery.list(d)
    end

    # A save can fail, and a failed save drops the checkpoint.
    test "a delete_by_slug that removes nothing does not save", %{d: d, path: path} do
      {:ok, kept, :new} = Discovery.add("kept", "mqtt", %{}, d)

      File.mkdir_p!(path <> ".tmp")
      assert {:ok, []} = Discovery.delete_by_slug("someone_else", d)

      d = restart_checkpointed(path)

      assert [^kept] = Discovery.list(d)
    end

    # A privately-named instance falling back to the default path would read
    # and overwrite the application Discovery's checkpoint.
    test "a privately-named instance without a :path keeps nothing across a restart" do
      name = :"disc_#{System.unique_integer([:positive])}"

      d = start_supervised!({Discovery, name: name}, id: :pathless)
      {:ok, _msg, :new} = Discovery.add("memory_only", "mqtt", %{}, d)

      :ok = stop_supervised!(:pathless)
      d = start_supervised!({Discovery, name: name}, id: :pathless)

      assert [] = Discovery.list(d)
    end

    test "an unusable file starts it empty and working, naming only the path", %{
      path: path
    } do
      uuid = String.duplicate("a", 32)
      stale = %{uuid: uuid, addon: "stale", service: "mqtt", config: %{"password" => "pw-stale"}}
      not_hex = String.duplicate("A", 32)

      for content <- [
            "not a term",
            :erlang.term_to_binary(:nope),
            :erlang.term_to_binary(%{uuid => :nope}),
            :erlang.term_to_binary(%{uuid => %{stale | config: "pw-stale"}}),
            :erlang.term_to_binary(%{uuid => Map.delete(stale, :service)}),
            :erlang.term_to_binary(%{String.duplicate("b", 32) => stale}),
            :erlang.term_to_binary(%{not_hex => %{stale | uuid: not_hex}}),
            :erlang.term_to_binary(%{(uuid <> "/..") => %{stale | uuid: uuid <> "/.."}}),
            :erlang.term_to_binary(%URI{}),
            :erlang.term_to_binary(MapSet.new())
          ] do
        :ok = stop_supervised!(:checkpointed)
        File.write!(path, content)
        {d, log} = ExUnit.CaptureLog.with_log(fn -> start_checkpointed(path) end)

        assert log =~ "run state #{path} unusable"
        refute log =~ "pw-stale"
        assert [] = Discovery.list(d)
        assert {:ok, %{uuid: uuid}, :new} = Discovery.add("stale", "mqtt", %{}, d)
        assert [%{uuid: ^uuid}] = Discovery.list(d)
      end
    end

    # An older checkpoint surviving a failed save would bring a deleted
    # message back on the next restart.
    @tag :capture_log
    test "a failed save leaves the next start empty, not on the older checkpoint", %{
      d: d,
      path: path
    } do
      {:ok, gone, :new} = Discovery.add("gone", "mqtt", %{}, d)
      {:ok, bystander, :new} = Discovery.add("bystander", "mqtt", %{}, d)

      # The save writes `path <> ".tmp"` first; a directory there fails it.
      File.mkdir_p!(path <> ".tmp")
      assert {:ok, ^gone} = Discovery.delete(gone.uuid, "gone", d)
      assert [^bystander] = Discovery.list(d)

      d = restart_checkpointed(path)

      assert [] = Discovery.list(d)
    end
  end
end
