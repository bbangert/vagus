defmodule Vagus.Core.VersionsCeilingTest do
  # async: false — the enforce: false case flips process-global app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Vagus.Core.{Supported, Versions}

  @ceiling Supported.version()
  @above "2026.12.1"

  defp start_versions(feed, opts) do
    name = :"versions_ceiling_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.json")
    on_exit(fn -> File.rm(path) end)
    {:ok, feed_agent} = Agent.start_link(fn -> feed end)
    test = self()

    defaults = [
      name: name,
      path: path,
      fetch: fn -> {:ok, Agent.get(feed_agent, & &1)} end,
      notify: fn event ->
        send(test, {:notify, event})
        :ok
      end
    ]

    start_supervised!(%{
      id: name,
      start: {Versions, :start_link, [Keyword.merge(defaults, opts)]}
    })

    if installed = opts[:installed], do: :ok = Versions.set_installed(installed, name)
    %{server: name, feed: feed_agent}
  end

  # The send runs in its own process; its result reaches the server after the
  # notify fun has already messaged the test.
  defp settled(server) do
    if :sys.get_state(server).notice.sending, do: settled(server), else: server
  end

  defp new_feed(%{server: server, feed: agent}, feed) do
    Agent.update(agent, fn _ -> feed end)
    Versions.invalidate(server)
  end

  describe "latest/1 and update_available?/1 are clamped; feed/1 is not" do
    test "installed below the ceiling, feed above: the ceiling is offered" do
      %{server: s} = start_versions(@above, installed: "2026.10.0")

      assert Versions.feed(s) == @above
      assert Versions.latest(s) == @ceiling
      assert Versions.update_available?(s)
    end

    test "installed below the ceiling, feed below it: the feed is offered" do
      %{server: s} = start_versions("2026.10.2", installed: "2026.10.0")

      assert Versions.latest(s) == "2026.10.2"
      assert Versions.update_available?(s)
    end

    test "installed at the ceiling, feed above: no update" do
      %{server: s} = start_versions(@above, installed: @ceiling)

      assert Versions.latest(s) == @ceiling
      refute Versions.update_available?(s)
    end

    test "installed above the ceiling: offered nothing newer" do
      %{server: s} = start_versions("2027.1.0", installed: "2026.12.0")

      assert Versions.latest(s) == "2026.12.0"
      refute Versions.update_available?(s)
    end
  end

  describe "the held-update notification" do
    test "is raised once per feed version, naming both versions" do
      ctx = start_versions(@above, installed: "2026.10.0")

      Versions.latest(ctx.server)
      assert_receive {:notify, {:hold, @above}}

      ctx.server |> settled() |> Versions.latest()
      Versions.update_available?(ctx.server)
      refute_receive {:notify, _}

      settled(ctx.server)
      new_feed(ctx, "2027.1.0")
      Versions.latest(ctx.server)
      assert_receive {:notify, {:hold, "2027.1.0"}}

      assert %{"notification_id" => "vagus_core_update_held", "message" => message} =
               Versions.notification(@above)

      assert message ==
               "Home Assistant Core #{@above} is available; this Vagus release supports up to " <>
                 "#{@ceiling}. It will be offered after the next Vagus update."
    end

    test "is dismissed once the feed is no longer above the ceiling" do
      ctx = start_versions(@above, installed: "2026.10.0")
      Versions.latest(ctx.server)
      assert_receive {:notify, {:hold, @above}}

      settled(ctx.server)
      new_feed(ctx, @ceiling)
      Versions.latest(ctx.server)
      assert_receive {:notify, :dismiss}

      ctx.server |> settled() |> Versions.latest()
      refute_receive {:notify, _}
    end

    test "a rollback below the ceiling dismisses even when installed is at the ceiling" do
      ctx = start_versions(@above, installed: @ceiling)
      Versions.latest(ctx.server)
      assert_receive {:notify, {:hold, @above}}

      settled(ctx.server)
      new_feed(ctx, "2026.10.2")
      Versions.latest(ctx.server)
      assert_receive {:notify, :dismiss}
    end

    test "is dismissed once Core reaches the feed version" do
      ctx = start_versions(@above, installed: "2026.10.0")
      Versions.latest(ctx.server)
      assert_receive {:notify, {:hold, @above}}

      :ok = ctx.server |> settled() |> then(&Versions.set_installed(@above, &1))
      assert_receive {:notify, :dismiss}
    end

    test "the first feed after a boot dismisses one an older release left behind" do
      ctx = start_versions("2026.10.2", installed: "2026.10.0")

      Versions.latest(ctx.server)
      assert_receive {:notify, :dismiss}

      ctx.server |> settled() |> Versions.latest()
      refute_receive {:notify, _}
    end

    test "a send that fails is retried at the next call" do
      test = self()
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      notify = fn event ->
        send(test, {:notify, event})
        if Agent.get_and_update(attempts, &{&1, &1 + 1}) == 0, do: {:error, :core_down}, else: :ok
      end

      ctx = start_versions(@above, installed: "2026.10.0", notify: notify)

      Versions.latest(ctx.server)
      assert_receive {:notify, {:hold, @above}}
      ctx.server |> settled() |> Versions.latest()
      assert_receive {:notify, {:hold, @above}}
      ctx.server |> settled() |> Versions.latest()
      refute_receive {:notify, _}
    end

    test "nothing is sent before a feed is known" do
      %{server: s} =
        start_versions(nil, installed: "2026.10.0", fetch: fn -> {:error, :offline} end)

      assert Versions.latest(s) == nil
      refute_receive {:notify, _}
    end
  end

  describe "enforce: false" do
    setup do
      Application.put_env(:vagus, Supported, enforce: false)
      on_exit(fn -> Application.delete_env(:vagus, Supported) end)
    end

    test "offers the raw feed, holds nothing, and warns at start" do
      log =
        capture_log(fn ->
          send(self(), {:ctx, start_versions(@above, installed: "2026.10.0")})
        end)

      assert log =~ "enforce is off"
      assert_received {:ctx, %{server: s}}

      assert Versions.latest(s) == @above
      assert Versions.update_available?(s)
      assert_receive {:notify, :dismiss}
      refute_receive {:notify, {:hold, _}}
    end
  end
end
