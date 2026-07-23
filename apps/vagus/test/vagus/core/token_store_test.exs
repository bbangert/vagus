defmodule Vagus.Core.TokenStoreTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.TokenStore

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "vagus_test_token_store_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  defp start_store(path, name \\ nil) do
    name = name || :"token_store_#{System.unique_integer([:positive])}"
    # An explicit :id (matching :name) rather than the {TokenStore, opts}
    # shorthand - that shorthand's child_spec/1 always derives id: TokenStore,
    # which would collide across the multiple differently-named instances
    # some of these tests start, and wouldn't be stop_supervised!-able by name.
    start_supervised!(%{id: name, start: {TokenStore, :start_link, [[name: name, path: path]]}})
    name
  end

  describe "put_options/2 + get_refresh_token/1 round-trip" do
    test "a posted refresh_token is readable back", %{path: path} do
      store = start_store(path)

      assert TokenStore.get_refresh_token(store) == nil
      assert :ok = TokenStore.put_options(%{"refresh_token" => "abc123"}, store)
      assert TokenStore.get_refresh_token(store) == "abc123"
    end

    test "unknown fields are ignored gracefully", %{path: path} do
      store = start_store(path)

      assert :ok =
               TokenStore.put_options(
                 %{"refresh_token" => "abc123", "totally_unknown_field" => "nope"},
                 store
               )

      assert TokenStore.get_refresh_token(store) == "abc123"
    end

    test "an options-only call with no refresh_token is still :ok", %{path: path} do
      store = start_store(path)

      assert :ok = TokenStore.put_options(%{"ssl" => true, "port" => 8123}, store)
      assert TokenStore.get_refresh_token(store) == nil
    end

    test "accepts every field listed in accepted_fields/0", %{path: path} do
      store = start_store(path)

      fields = Map.new(TokenStore.accepted_fields(), &{&1, "value"})
      assert :ok = TokenStore.put_options(fields, store)
    end
  end

  describe "idempotent re-put" do
    test "putting the same refresh_token twice is harmless", %{path: path} do
      store = start_store(path)

      assert :ok = TokenStore.put_options(%{"refresh_token" => "same-token"}, store)
      assert :ok = TokenStore.put_options(%{"refresh_token" => "same-token"}, store)
      assert TokenStore.get_refresh_token(store) == "same-token"
    end
  end

  describe "file persistence across process restart" do
    test "a value posted before a restart is still there after", %{path: path} do
      store = start_store(path, :persistence_test_store)
      assert :ok = TokenStore.put_options(%{"refresh_token" => "persisted-token"}, store)

      stop_supervised!(store)
      start_supervised!({TokenStore, name: store, path: path})

      assert TokenStore.get_refresh_token(store) == "persisted-token"
    end

    test "starting fresh against a nonexistent file has no refresh token", %{path: path} do
      refute File.exists?(path)
      store = start_store(path)
      assert TokenStore.get_refresh_token(store) == nil
    end
  end

  describe "subscribe/1 notification" do
    test "a subscriber is notified when a refresh token first lands", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.subscribe(store)

      assert :ok = TokenStore.put_options(%{"refresh_token" => "new-token"}, store)
      assert_receive {:token_store, :refresh_token_available}
    end

    test "a subscriber is notified again when the refresh token changes value", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.put_options(%{"refresh_token" => "token-1"}, store)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"refresh_token" => "token-2"}, store)
      assert_receive {:token_store, :refresh_token_available}
    end

    test "a subscriber is NOT re-notified for an idempotent re-put of the same token", %{
      path: path
    } do
      store = start_store(path)
      :ok = TokenStore.put_options(%{"refresh_token" => "stable-token"}, store)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"refresh_token" => "stable-token"}, store)
      refute_receive {:token_store, :refresh_token_available}, 50
    end

    test "an options-only put (no refresh_token) does not notify", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"ssl" => true}, store)
      refute_receive {:token_store, :refresh_token_available}, 50
    end
  end

  describe "get_watchdog/1" do
    test "defaults to true when the field was never posted", %{path: path} do
      store = start_store(path)
      assert TokenStore.get_watchdog(store) == true
    end

    test "returns the posted boolean and persists it across restart", %{path: path} do
      store = start_store(path, :watchdog_persistence_store)
      :ok = TokenStore.put_options(%{"watchdog" => false}, store)
      assert TokenStore.get_watchdog(store) == false

      stop_supervised!(store)
      start_supervised!({TokenStore, name: store, path: path})
      assert TokenStore.get_watchdog(store) == false
    end
  end

  describe "watchdog_changed notification" do
    test "flipping the watchdog value notifies subscribers", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"watchdog" => false}, store)
      assert_receive {:token_store, :watchdog_changed}

      :ok = TokenStore.put_options(%{"watchdog" => true}, store)
      assert_receive {:token_store, :watchdog_changed}
    end

    test "an idempotent re-put of the same value does not notify", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.put_options(%{"watchdog" => false}, store)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"watchdog" => false}, store)
      refute_receive {:token_store, :watchdog_changed}, 50
    end

    test "a first-ever watchdog: true put matches the default and does not notify", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"watchdog" => true}, store)
      refute_receive {:token_store, :watchdog_changed}, 50
    end

    test "a watchdog flip does not also fire the refresh-token notification", %{path: path} do
      store = start_store(path)
      :ok = TokenStore.subscribe(store)

      :ok = TokenStore.put_options(%{"watchdog" => false}, store)
      refute_receive {:token_store, :refresh_token_available}, 50
    end
  end
end
