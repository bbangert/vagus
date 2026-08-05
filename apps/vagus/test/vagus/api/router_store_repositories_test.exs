defmodule Vagus.API.RouterStoreRepositoriesTest do
  @moduledoc """
  Issue #5, phase 4 — the five `/store/repositories*` routes. Store-level
  behavior (duplicate/invalid/busy semantics, persistence, in-use guards) is
  proven exhaustively against isolated `Store` instances in
  `Vagus.Addon.StoreTest`'s "runtime add/remove/repair" describe block; this
  file only proves the router maps each `Vagus.Addon.Store` result onto the
  right envelope/status/message (the contract cheat-sheet in
  `.claude/plans/store-repositories/research/upstream-contract.md`).

  `async: false`: the router always calls the globally-supervised
  `Vagus.Addon.Store` singleton (there is no way to inject a per-test server
  through HTTP, same reason `Vagus.API.AddonAssetsRouterTest`/
  `Vagus.API.AddonLifecycleRouterTest` are `async: false`), and the add/repair
  happy paths need a **non-network** fetcher — the global singleton's real
  `config :vagus, :store_fetcher` (defaulting to the live-HTTP
  `Vagus.Addon.Store.HTTPFetcher`) would otherwise reach out to the network
  from a hermetic test run. `Store` exposes no runtime fetcher-swap API (by
  design — see its moduledoc: fetching is an `init/1`-time seam for
  test-owned instances, not a thing the running singleton hands out), so each
  test in this file swaps the singleton's `:fetcher`/`:repositories`/`:path`
  fields via `:sys.replace_state/2` and restores the exact snapshot taken
  before the swap in `on_exit` — the same "seed the singleton directly"
  seam the sibling files use for `:catalog`, just reached through `:sys`
  because fetcher/path aren't exposed via a `{:put_..., ...}` call. Every
  `async: false` file in this suite runs serialized with the others (ExUnit
  runs the whole async phase first), so there is no concurrent reader to
  disturb.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Vagus.Addon.{Config, State, Store}
  alias Vagus.Addon.Store.RepositorySpec
  alias Vagus.API.{Router, Token}

  @opts Router.init([])

  @awesome "https://github.com/awesome-developer/awesome-repo"
  @awesome_slug RepositorySpec.slug(@awesome)

  @esphome_yaml """
  name: ESPHome
  version: "2025.1.0"
  slug: esphome
  description: ESPHome dashboard
  arch:
    - aarch64
  image: esphome/{arch}-addon
  """

  # Matches on `:url` (runtime-added repos are keyed by a hash of the full
  # posted string, never a fixed slug) — same shape as
  # `Vagus.Addon.StoreTest.MutationFetcher`, trimmed to what this file's
  # routes need.
  defmodule FixtureFetcher do
    def fetch(%{url: "https://github.com/awesome-developer/awesome-repo"}) do
      {:ok,
       [
         {"repository.json", ~s({"name": "Awesome add-ons", "maintainer": "Awesome Dev"})},
         {"esphome/config.yaml", Vagus.API.RouterStoreRepositoriesTest.esphome_yaml()}
       ]}
    end

    # Fetches fine, ships an add-on, but no `repository.{json,yaml,yml}` —
    # upstream's own bar for "not an add-on repository". A github.com host so it
    # clears `RepositorySpec.ensure_safe/1`'s host gate and reaches the fetch.
    def fetch(%{url: "https://github.com/example/no-repository-file"}) do
      {:ok, [{"esphome/config.yaml", Vagus.API.RouterStoreRepositoriesTest.esphome_yaml()}]}
    end

    def fetch(%{url: "https://github.com/example/gone"}), do: {:error, :nxdomain}
    def fetch(%{url: "https://example.test/broken"}), do: {:error, :nxdomain}
  end

  def esphome_yaml, do: @esphome_yaml

  defp call(conn), do: Router.call(conn, @opts)
  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> Token.get())
  defp req_json(conn), do: put_req_header(conn, "content-type", "application/json")
  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp get_(path), do: conn(:get, path) |> authed() |> call()
  defp delete_(path), do: conn(:delete, path) |> authed() |> call()

  defp post_(path, body \\ %{}) do
    conn(:post, path, Jason.encode!(body)) |> authed() |> req_json() |> call()
  end

  # Swaps the running singleton's fetcher/repositories/persisted-sources/path
  # to a hermetic, isolated baseline for the duration of one test, and
  # restores the exact pre-swap snapshot afterwards — see moduledoc.
  defp isolate_store do
    original = :sys.get_state(Store)

    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_test_router_store_repositories_#{System.unique_integer([:positive])}.json"
      )

    :sys.replace_state(Store, fn state ->
      %{
        state
        | fetcher: FixtureFetcher,
          repositories: [],
          persisted_sources: [],
          path: path,
          catalog: %{},
          repository_meta: %{}
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Store, fn _state -> original end)
      File.rm(path)
    end)

    :ok
  end

  # Bypasses `add_repository/2`'s fetch-and-validate gate entirely — used only
  # for the repair-fetch-failed case, where the point is a repository that was
  # already on the books (config-declared, in upstream's real usage) and fails
  # a *later* reload, not one this test is trying to add.
  defp seed_broken_repository do
    :sys.replace_state(Store, fn state ->
      %{
        state
        | repositories: [%{slug: "broken", url: "https://example.test/broken"}]
      }
    end)
  end

  defp fixture_config(slug) do
    {:ok, config} =
      Config.parse(%{
        "name" => "Installed",
        "version" => "1.0.0",
        "slug" => slug,
        "description" => "an installed add-on",
        "arch" => ["aarch64"],
        "image" => "x/y"
      })

    config
  end

  setup do
    isolate_store()
  end

  describe "GET /store/repositories" do
    test "empty store -> 200, bare empty array" do
      conn = get_("/store/repositories")
      assert conn.status == 200
      assert json_body(conn)["data"] == []
    end

    test "returns the bare array of 5-key repository objects, nothing wrapping it" do
      assert :ok = Store.add_repository(@awesome)

      conn = get_("/store/repositories")
      assert conn.status == 200
      data = json_body(conn)["data"]
      assert is_list(data)
      assert [repo] = data
      assert MapSet.new(Map.keys(repo)) == MapSet.new(~w(slug name source url maintainer))
      assert repo["slug"] == @awesome_slug
      assert repo["name"] == "Awesome add-ons"
      assert repo["source"] == @awesome
      assert repo["url"] == @awesome
      assert repo["maintainer"] == "Awesome Dev"
    end

    test "unauthenticated -> 401" do
      conn = conn(:get, "/store/repositories") |> call()
      assert conn.status == 401
    end
  end

  describe "GET /store/repositories/:slug" do
    test "known slug -> 200, single object" do
      assert :ok = Store.add_repository(@awesome)

      conn = get_("/store/repositories/#{@awesome_slug}")
      assert conn.status == 200
      assert json_body(conn)["data"]["slug"] == @awesome_slug
    end

    test "unknown slug -> 404 with the exact message" do
      conn = get_("/store/repositories/deadbeef")
      assert conn.status == 404
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] == "Repository deadbeef does not exist in the store"
    end
  end

  describe "POST /store/repositories" do
    test "happy path -> 200, empty data, and the repo is live" do
      conn = post_("/store/repositories", %{"repository" => @awesome})
      assert conn.status == 200
      assert json_body(conn)["data"] == %{}

      assert Enum.any?(Store.repositories(), &(&1.slug == @awesome_slug))
    end

    test "duplicate -> 409 with upstream's exact wording" do
      assert :ok = Store.add_repository(@awesome)

      conn = post_("/store/repositories", %{"repository" => @awesome})
      assert conn.status == 409
      body = json_body(conn)
      assert body["result"] == "error"
      assert body["message"] == "Can't add #{@awesome}, already in the store"
    end

    test "invalid format -> 400 exact message" do
      conn = post_("/store/repositories", %{"repository" => "not a repository at all"})
      assert conn.status == 400
      assert json_body(conn)["message"] == "No valid repository format!"
    end

    test "candidate fetch fails -> 400, invalid_repository wording" do
      conn = post_("/store/repositories", %{"repository" => "https://github.com/example/gone"})
      assert conn.status == 400

      assert json_body(conn)["message"] ==
               "https://github.com/example/gone is not a valid add-on repository"
    end

    test "candidate has no repository.{json,yaml,yml} -> 400, invalid_repository wording" do
      conn =
        post_("/store/repositories", %{
          "repository" => "https://github.com/example/no-repository-file"
        })

      assert conn.status == 400

      assert json_body(conn)["message"] ==
               "https://github.com/example/no-repository-file is not a valid add-on repository"
    end

    test "a decoupling payload (non-github host) -> 400 invalid-format wording" do
      conn = post_("/store/repositories", %{"repository" => "https://notgithub.com/a/b"})
      assert conn.status == 400
      assert json_body(conn)["message"] == "No valid repository format!"
      refute Enum.any?(Store.repositories(), &(&1.url == "https://notgithub.com/a/b"))
    end

    test "a decoupling payload (ref path-traversal) -> 400 invalid-format wording" do
      traversal = "https://github.com/home-assistant/addons/#../../../attacker/evil/tar.gz/main"
      conn = post_("/store/repositories", %{"repository" => traversal})
      assert conn.status == 400
      assert json_body(conn)["message"] == "No valid repository format!"
    end

    test "contention with the reload mutex -> 409 busy" do
      # Hold the exact `:global` reload lock the singleton takes so the router's
      # add attempt (`retries: 0`) aborts immediately — deterministic, no race:
      # the POST only runs while the lock is provably held, and the holder is
      # released only after. Same lock resource `Vagus.Addon.Store` keys its
      # reload/mutation mutex on.
      parent = self()

      holder =
        spawn(fn ->
          :global.trans(
            {{:store_reload, Store}, self()},
            fn ->
              send(parent, :locked)

              receive do
                :release -> :ok
              end
            end,
            [node()],
            0
          )
        end)

      assert_receive :locked, 5_000

      conn = post_("/store/repositories", %{"repository" => @awesome})
      send(holder, :release)

      assert conn.status == 409
      assert json_body(conn)["message"] == "a store operation is already in progress"
    end

    test "missing repository key -> 400" do
      conn = post_("/store/repositories", %{})
      assert conn.status == 400
      assert json_body(conn)["message"] == "No valid repository format!"
    end

    test "extra keys -> 400, unknown-keys wording" do
      conn = post_("/store/repositories", %{"repository" => @awesome, "extra" => "nope"})
      assert conn.status == 400
      assert json_body(conn)["message"] =~ "unknown keys"
      assert json_body(conn)["message"] =~ "extra"
    end

    test "non-string repository value -> 400" do
      conn = post_("/store/repositories", %{"repository" => 123})
      assert conn.status == 400
      assert json_body(conn)["message"] == "No valid repository format!"
    end

    # `Plug.ErrorHandler` sends the response then unconditionally re-raises
    # (see `Vagus.API.RouterTest`'s "malformed request body" describe for the
    # full explanation) — under `Plug.Test`'s direct `call/2` there's no
    # adapter to swallow that reraise, so the test catches it and reads the
    # response `Plug.Test` already delivered to this process's mailbox.
    test "malformed JSON body -> 400" do
      conn = conn(:post, "/store/repositories", "{not json") |> authed() |> req_json()
      {Plug.Adapters.Test.Conn, %{ref: ref}} = conn.adapter

      assert_raise Plug.Parsers.ParseError, fn -> call(conn) end

      assert_received {^ref, {400, _headers, resp_body}}
      assert Jason.decode!(resp_body)["message"] == "invalid JSON body"
    end

    test "unauthenticated -> 401" do
      conn =
        conn(:post, "/store/repositories", Jason.encode!(%{"repository" => @awesome}))
        |> req_json()
        |> call()

      assert conn.status == 401
    end
  end

  describe "DELETE /store/repositories/:slug" do
    test "happy path -> 200, empty data, and the repo is gone" do
      assert :ok = Store.add_repository(@awesome)

      conn = delete_("/store/repositories/#{@awesome_slug}")
      assert conn.status == 200
      assert json_body(conn)["data"] == %{}
      refute Enum.any?(Store.repositories(), &(&1.slug == @awesome_slug))
    end

    test "unknown slug -> 404 exact message" do
      conn = delete_("/store/repositories/deadbeef")
      assert conn.status == 404
      assert json_body(conn)["message"] == "Repository deadbeef does not exist in the store"
    end

    test "built-in repository -> 400 exact message" do
      # Config-declared repos aren't in the persisted set — swap one in
      # directly (repositories: [] is this file's isolated baseline; adding
      # via `Store.add_repository/2` would make it persisted, not built-in).
      :sys.replace_state(Store, fn state ->
        %{
          state
          | repositories: [%{slug: "core", url: "https://github.com/home-assistant/addons"}]
        }
      end)

      conn = delete_("/store/repositories/core")
      assert conn.status == 400
      assert json_body(conn)["message"] == "Can't remove built-in repositories!"
    end

    test "in-use repository -> 400, quoting the source" do
      assert :ok = Store.add_repository(@awesome)
      store_slug = "#{@awesome_slug}_esphome"

      :ok = State.put(fixture_config(store_slug), :started)
      on_exit(fn -> State.delete(store_slug) end)

      conn = delete_("/store/repositories/#{@awesome_slug}")
      assert conn.status == 400

      assert json_body(conn)["message"] ==
               "Can't remove '#{@awesome}'. It's used by installed add-ons"

      # Nothing removed — still there for the on_exit cleanup below.
      assert Enum.any?(Store.repositories(), &(&1.slug == @awesome_slug))
    end

    test "unauthenticated -> 401" do
      conn = conn(:delete, "/store/repositories/#{@awesome_slug}") |> call()
      assert conn.status == 401
    end
  end

  describe "POST /store/repositories/:slug/repair" do
    test "happy path -> 200, empty data" do
      assert :ok = Store.add_repository(@awesome)

      conn = post_("/store/repositories/#{@awesome_slug}/repair")
      assert conn.status == 200
      assert json_body(conn)["data"] == %{}
    end

    test "unknown slug -> 404 exact message" do
      conn = post_("/store/repositories/deadbeef/repair")
      assert conn.status == 404
      assert json_body(conn)["message"] == "Repository deadbeef does not exist in the store"
    end

    test "fetch-failed -> 400, honest message with the fetch error" do
      seed_broken_repository()

      conn = post_("/store/repositories/broken/repair")
      assert conn.status == 400
      assert json_body(conn)["message"] == "Repository broken could not be fetched: :nxdomain"
    end
  end
end
