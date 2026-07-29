defmodule Vagus.Addon.Store.RefresherTest do
  @moduledoc """
  `Vagus.Addon.Store.Refresher` — the boot-time catalog fill.

  Drives a real `Vagus.Addon.Store` with a fetcher whose results the test
  controls, rather than asserting on the refresher's internals: what matters
  is that the catalog ends up populated without anyone calling
  `POST /store/reload`.
  """
  use ExUnit.Case, async: false

  alias Vagus.Addon.Store
  alias Vagus.Addon.Store.Refresher

  @config """
  name: Test Addon
  version: "1"
  slug: test
  description: d
  arch:
    - amd64
  image: x/y
  """

  # Fails until the test flips a flag, standing in for a device whose network
  # isn't up yet — the case the retry exists for. Counts its calls so a test
  # can assert how many attempts were actually made, which is the only way to
  # tell "gave up" apart from "still retrying".
  defmodule FlakyFetcher do
    def fetch(%{slug: "core"}) do
      :counters.add(counter(), 1, 1)

      cond do
        :persistent_term.get({__MODULE__, :raise}, false) ->
          raise "boom"

        :persistent_term.get({__MODULE__, :online}, false) ->
          {:ok, [{"test/config.yaml", Vagus.Addon.Store.RefresherTest.config()}]}

        true ->
          {:error, :nxdomain}
      end
    end

    def counter, do: :persistent_term.get({__MODULE__, :counter})

    def reset_counter, do: :persistent_term.put({__MODULE__, :counter}, :counters.new(1, []))

    def attempts, do: :counters.get(counter(), 1)
  end

  def config, do: @config

  @repos [%{slug: "core", url: "https://example.test/repo"}]

  setup do
    FlakyFetcher.reset_counter()

    on_exit(fn ->
      :persistent_term.erase({FlakyFetcher, :online})
      :persistent_term.erase({FlakyFetcher, :raise})
      :persistent_term.erase({FlakyFetcher, :counter})
    end)

    :ok
  end

  defp start_store do
    start_supervised!({Store, name: nil, fetcher: FlakyFetcher, repositories: @repos})
  end

  test "the catalog fills after boot without anyone calling /store/reload" do
    :persistent_term.put({FlakyFetcher, :online}, true)
    store = start_store()

    assert Store.catalog(store) == %{}

    start_supervised!(
      {Refresher, force: true, store: store, initial_delay_ms: 0, name: :refresher_ok}
    )

    assert eventually(fn -> map_size(Store.catalog(store)) == 1 end)
  end

  test "an empty catalog is retried, and a later-arriving network still populates it" do
    # `Store.reload/1` reports a failed repository as `{:ok, 0}`, not an
    # error, so the retry has to key on the count.
    store = start_store()

    start_supervised!(
      {Refresher,
       force: true,
       store: store,
       initial_delay_ms: 0,
       backoff_ms: [50, 50],
       name: :refresher_retry}
    )

    assert eventually(fn -> map_size(Store.catalog(store)) == 0 end)

    :persistent_term.put({FlakyFetcher, :online}, true)

    assert eventually(fn -> map_size(Store.catalog(store)) == 1 end)
  end

  test "it gives up after the configured retries rather than fetching forever" do
    # This asserts the ATTEMPT COUNT, not "the catalog is still empty" — an
    # empty catalog holds whether the backoff correctly ran out or the retry
    # loops forever, so the earlier version of this test passed either way.
    # `backoff_ms: [10]` means exactly two fetches: the initial one, one retry.
    store = start_store()

    start_supervised!(
      {Refresher,
       force: true, store: store, initial_delay_ms: 0, backoff_ms: [10], name: :refresher_giveup}
    )

    assert eventually(fn -> FlakyFetcher.attempts() == 2 end)

    # ...and it stays 2. A refresher that kept scheduling would climb here.
    Process.sleep(150)
    assert FlakyFetcher.attempts() == 2

    assert :refresher_giveup |> Process.whereis() |> Process.alive?()
    assert Store.catalog(store) == %{}
  end

  test "it stops fetching once the store is populated" do
    # The counterpart: success must also end the loop, not leave a timer
    # re-fetching every repository forever.
    :persistent_term.put({FlakyFetcher, :online}, true)
    store = start_store()

    start_supervised!(
      {Refresher,
       force: true, store: store, initial_delay_ms: 0, backoff_ms: [10, 10], name: :refresher_idle}
    )

    assert eventually(fn -> map_size(Store.catalog(store)) == 1 end)

    attempts = FlakyFetcher.attempts()
    Process.sleep(150)
    assert FlakyFetcher.attempts() == attempts
  end

  test "a fetcher that raises is retried, not fatal to the refresher" do
    # Covers `attempt/1`'s rescue: a repository that blows up mid-parse must
    # not take the boot helper down with it.
    :persistent_term.put({FlakyFetcher, :raise}, true)
    store = start_store()

    start_supervised!(
      {Refresher,
       force: true, store: store, initial_delay_ms: 0, backoff_ms: [10], name: :refresher_raise}
    )

    assert eventually(fn -> FlakyFetcher.attempts() >= 2 end)
    assert :refresher_raise |> Process.whereis() |> Process.alive?()
  end

  test "start_link/1 declines unless the config gate is set" do
    assert :ignore = Refresher.start_link([])
  end

  defp eventually(fun, attempts \\ 60) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(25)
        {:cont, false}
      end
    end)
  end
end
