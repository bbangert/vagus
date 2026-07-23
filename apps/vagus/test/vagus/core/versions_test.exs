defmodule Vagus.Core.VersionsTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.Versions

  ## Helpers

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "vagus_test_versions_#{System.unique_integer([:positive])}.json"
    )
  end

  defp start_versions(opts) do
    name = :"versions_#{System.unique_integer([:positive])}"

    # An explicit :id (matching :name) rather than the {Versions, opts}
    # shorthand - that shorthand's child_spec/1 always derives id: Versions,
    # which would collide across the multiple differently-named instances
    # some of these tests start, and wouldn't be stop_supervised!-able by
    # name (see token_store_test.exs's identical helper).
    start_supervised!(%{
      id: name,
      start: {Versions, :start_link, [Keyword.put(opts, :name, name)]}
    })

    name
  end

  # An always-failing fetch — used by tests that only care about
  # installed/seed persistence and shouldn't ever invoke it.
  defp never_fetch, do: fn -> flunk_fetch() end
  defp flunk_fetch, do: raise("fetch/0 should not have been called")

  # Counts invocations via a fixed-name Agent (this module's tests always
  # run serially against their own private server, so a per-test unique
  # agent name is enough — no cross-test collision).
  defp counting_fetch(agent, result_fn) do
    fn ->
      Agent.update(agent, &(&1 + 1))
      result_fn.()
    end
  end

  defp start_counter,
    do: start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> 0 end]}})

  defp count(agent), do: Agent.get(agent, & &1)

  defp start_clock_agent(initial \\ 0),
    do: start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> initial end]}})

  defp clock_fun(agent), do: fn -> Agent.get(agent, & &1) end
  defp advance_clock(agent, ms), do: Agent.update(agent, &(&1 + ms))

  @day_ms 24 * 60 * 60 * 1_000

  describe "installed/1 + set_installed/2 persistence round-trip" do
    test "a value set is readable back on the same server" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions = start_versions(path: path, fetch: never_fetch())

      assert Versions.installed(versions) == nil
      assert :ok = Versions.set_installed("2026.7.0", versions)
      assert Versions.installed(versions) == "2026.7.0"
    end

    test "a value set before a restart is still there after, via a fresh server on the same path" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions1 = start_versions(path: path, fetch: never_fetch())

      assert :ok = Versions.set_installed("2026.7.1", versions1)
      stop_supervised!(versions1)

      versions2 = start_versions(path: path, fetch: never_fetch())
      assert Versions.installed(versions2) == "2026.7.1"
    end

    test "set_installed/2 always overwrites, even when a value is already persisted" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions = start_versions(path: path, fetch: never_fetch())

      assert :ok = Versions.set_installed("2026.7.0", versions)
      assert :ok = Versions.set_installed("2026.8.0", versions)
      assert Versions.installed(versions) == "2026.8.0"
    end

    test "starting fresh against a nonexistent file has no installed version" do
      path = tmp_path()
      refute File.exists?(path)
      versions = start_versions(path: path, fetch: never_fetch())
      assert Versions.installed(versions) == nil
    end
  end

  describe "seed/2 only-if-nil semantics" do
    test "seeds when nothing is installed yet" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions = start_versions(path: path, fetch: never_fetch())

      assert :ok = Versions.seed("2026.7.0", versions)
      assert Versions.installed(versions) == "2026.7.0"
    end

    test "does not clobber an already-persisted value" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions = start_versions(path: path, fetch: never_fetch())

      assert :ok = Versions.set_installed("2026.7.0", versions)
      assert :ok = Versions.seed("2026.9.0", versions)
      assert Versions.installed(versions) == "2026.7.0"
    end

    test "a seed persists to disk (visible to a fresh server on the same path)" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions1 = start_versions(path: path, fetch: never_fetch())

      assert :ok = Versions.seed("2026.7.2", versions1)
      stop_supervised!(versions1)

      versions2 = start_versions(path: path, fetch: never_fetch())
      assert Versions.installed(versions2) == "2026.7.2"
    end
  end

  describe "latest/1 caching (injected fetch + clock)" do
    test "a second call within 24h does not re-fetch" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      counter = start_counter()
      clock = start_clock_agent()

      versions =
        start_versions(
          path: path,
          now: clock_fun(clock),
          fetch: counting_fetch(counter, fn -> {:ok, "2026.7.5"} end)
        )

      assert Versions.latest(versions) == "2026.7.5"
      advance_clock(clock, 1_000)
      assert Versions.latest(versions) == "2026.7.5"
      assert count(counter) == 1
    end

    test "advancing the clock past 24h triggers a re-fetch" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      counter = start_counter()
      clock = start_clock_agent()

      versions =
        start_versions(
          path: path,
          now: clock_fun(clock),
          fetch: counting_fetch(counter, fn -> {:ok, "2026.7.5"} end)
        )

      assert Versions.latest(versions) == "2026.7.5"
      advance_clock(clock, @day_ms + 1)
      assert Versions.latest(versions) == "2026.7.5"
      assert count(counter) == 2
    end

    test "a fetch error with no prior cache returns nil" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)

      versions =
        start_versions(path: path, fetch: fn -> {:error, :nxdomain} end)

      assert Versions.latest(versions) == nil
    end

    test "a fetch error with a stale cache falls back to the cached value" do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      clock = start_clock_agent()

      script =
        start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> :ok_first end]}})

      fetch = fn ->
        case Agent.get_and_update(script, fn s -> {s, :error_after} end) do
          :ok_first -> {:ok, "2026.7.5"}
          :error_after -> {:error, :nxdomain}
        end
      end

      versions = start_versions(path: path, now: clock_fun(clock), fetch: fetch)

      assert Versions.latest(versions) == "2026.7.5"
      advance_clock(clock, @day_ms + 1)
      # Cache is stale, so this call re-fetches; the fetch fails but the
      # stale value is returned rather than nil.
      assert Versions.latest(versions) == "2026.7.5"
    end
  end

  describe "update_available?/1 matrix" do
    defp with_versions(installed, latest_result) do
      path = tmp_path()
      on_exit(fn -> File.rm(path) end)
      versions = start_versions(path: path, fetch: fn -> latest_result end)
      if installed, do: :ok = Versions.set_installed(installed, versions)
      versions
    end

    test "installed nil, latest known -> false" do
      versions = with_versions(nil, {:ok, "2026.7.5"})
      refute Versions.update_available?(versions)
    end

    test "installed known, latest nil (fetch error) -> false" do
      versions = with_versions("2026.7.0", {:error, :nxdomain})
      refute Versions.update_available?(versions)
    end

    test "installed == latest -> false" do
      versions = with_versions("2026.7.5", {:ok, "2026.7.5"})
      refute Versions.update_available?(versions)
    end

    test "installed != latest -> true" do
      versions = with_versions("2026.7.0", {:ok, "2026.7.5"})
      assert Versions.update_available?(versions)
    end
  end
end
