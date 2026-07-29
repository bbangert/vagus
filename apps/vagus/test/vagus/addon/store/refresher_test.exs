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
  # isn't up yet — the case the retry exists for.
  defmodule FlakyFetcher do
    def fetch(%{slug: "core"}) do
      if :persistent_term.get({__MODULE__, :online}, false) do
        {:ok, [{"test/config.yaml", Vagus.Addon.Store.RefresherTest.config()}]}
      else
        {:error, :nxdomain}
      end
    end
  end

  def config, do: @config

  @repos [%{slug: "core", url: "https://example.test/repo"}]

  setup do
    on_exit(fn -> :persistent_term.erase({FlakyFetcher, :online}) end)
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

  test "it gives up rather than retrying forever, leaving the store usable" do
    store = start_store()

    start_supervised!(
      {Refresher,
       force: true, store: store, initial_delay_ms: 0, backoff_ms: [10], name: :refresher_giveup}
    )

    # Both attempts land inside this window; the process must still be alive
    # and the store must still answer.
    Process.sleep(120)

    assert Process.whereis(:refresher_giveup) |> Process.alive?()
    assert Store.catalog(store) == %{}
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
