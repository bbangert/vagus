defmodule Vagus.Core.UsersTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.Users

  # No live Core WS here: `Vagus.Core.Users` takes its `config/auth/list`
  # command function as an injected seam, so the admin derivation and the
  # cache are exercised against scripted responses. Each test gets its own
  # named cache GenServer (the app's global `Vagus.Core.Users` is running
  # under `Vagus.Core.Supervisor`) so cached state never leaks between them.
  defp start_users(opts \\ []) do
    name = :"core_users_test_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Users, :start_link, [[{:name, name} | opts]]}})
    name
  end

  # Scripts one response per call, and echoes every invocation to the test
  # process so call counts can be asserted.
  defp scripted(responses) do
    agent =
      start_supervised!({Agent, fn -> responses end},
        id: {:scripted, System.unique_integer([:positive])}
      )

    test = self()

    fn payload, opts ->
      send(test, {:command_called, payload, opts})
      Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
    end
  end

  defp always(response) do
    test = self()

    fn payload, opts ->
      send(test, {:command_called, payload, opts})
      response
    end
  end

  defp call_count do
    count_calls(0)
  end

  defp count_calls(acc) do
    receive do
      {:command_called, _payload, _opts} -> count_calls(acc + 1)
    after
      0 -> acc
    end
  end

  # Shaped like Core's `_user_info/1` output - note the absence of any
  # `is_admin` key, which is the whole reason the derivation exists.
  defp user(overrides) do
    Map.merge(
      %{
        "id" => "user-id",
        "username" => "someone",
        "name" => "Someone",
        "is_owner" => false,
        "is_active" => true,
        "local_only" => false,
        "system_generated" => false,
        "group_ids" => ["system-users"],
        "credentials" => []
      },
      overrides
    )
  end

  describe "admin?/2 derivation" do
    test "an owner is an admin" do
      users = [user(%{"id" => "owner", "is_owner" => true, "group_ids" => []})]
      server = start_users()

      assert Users.admin?("owner", server: server, command_fun: always({:ok, users})) ==
               {:ok, true}
    end

    test "an active member of the system-admin group is an admin" do
      users = [user(%{"id" => "adm", "group_ids" => ["system-admin"]})]
      server = start_users()

      assert Users.admin?("adm", server: server, command_fun: always({:ok, users})) ==
               {:ok, true}
    end

    test "an INACTIVE owner is still an admin (Core's asymmetry)" do
      users = [
        user(%{"id" => "owner", "is_owner" => true, "is_active" => false, "group_ids" => []})
      ]

      server = start_users()

      assert Users.admin?("owner", server: server, command_fun: always({:ok, users})) ==
               {:ok, true}
    end

    test "an active user outside the admin group is not an admin" do
      users = [user(%{"id" => "plain", "group_ids" => ["system-users"]})]
      server = start_users()

      assert Users.admin?("plain", server: server, command_fun: always({:ok, users})) ==
               {:ok, false}
    end

    test "an INACTIVE non-owner in the admin group is not an admin" do
      users = [user(%{"id" => "stale", "is_active" => false, "group_ids" => ["system-admin"]})]
      server = start_users()

      assert Users.admin?("stale", server: server, command_fun: always({:ok, users})) ==
               {:ok, false}
    end

    test "a read-only user with no group_ids key at all is not an admin" do
      users = [Map.delete(user(%{"id" => "sparse"}), "group_ids")]
      server = start_users()

      assert Users.admin?("sparse", server: server, command_fun: always({:ok, users})) ==
               {:ok, false}
    end

    # `group_ids` must be a real list to be consulted: a scalar string would
    # otherwise read as membership if wrapped, handing the admin gate to any
    # malformed record Core sends.
    test "a scalar 'system-admin' group_ids is NOT admin" do
      users = [user(%{"id" => "scalar", "group_ids" => "system-admin"})]
      server = start_users()

      assert Users.admin?("scalar", server: server, command_fun: always({:ok, users})) ==
               {:ok, false}
    end

    for {label, value} <- [
          {"nil", nil},
          {"a map", %{"0" => "system-admin"}},
          {"a bare atom", :system_admin}
        ] do
      test "#{label} group_ids is not admin" do
        users = [user(%{"id" => "weird", "group_ids" => unquote(Macro.escape(value))})]
        server = start_users()

        assert Users.admin?("weird", server: server, command_fun: always({:ok, users})) ==
                 {:ok, false}
      end
    end

    test "an owner with malformed group_ids is still an admin (the owner branch is independent)" do
      users = [user(%{"id" => "owner", "is_owner" => true, "group_ids" => "system-admin"})]
      server = start_users()

      assert Users.admin?("owner", server: server, command_fun: always({:ok, users})) ==
               {:ok, true}
    end

    test "issues the config/auth/list command (WS-only, no REST equivalent)" do
      server = start_users()
      _ = Users.admin?("owner", server: server, command_fun: always({:ok, []}))

      assert_receive {:command_called, %{"type" => "config/auth/list"}, _opts}
    end
  end

  describe "admin?/2 for an id absent from the list" do
    test "is a definitive {:ok, false}, not an error" do
      users = [user(%{"id" => "someone-else", "is_owner" => true})]
      server = start_users()

      assert Users.admin?("nobody", server: server, command_fun: always({:ok, users})) ==
               {:ok, false}
    end
  end

  describe "names/2" do
    test "returns Core's login name and display name" do
      users = [user(%{"id" => "u1", "username" => "ben", "name" => "Ben Bangert"})]
      server = start_users()

      assert Users.names("u1", server: server, command_fun: always({:ok, users})) ==
               {:ok, %{username: "ben", name: "Ben Bangert"}}
    end

    # Core nulls both fields routinely (a system-generated user has no
    # username; a user may have no display name), and a consumer forwarding
    # them must be able to tell that from a real value.
    for {label, value} <- [{"null", nil}, {"an empty string", ""}, {"a non-string", 42}] do
      test "#{label} username/name reads as nil" do
        users = [
          user(%{
            "id" => "u1",
            "username" => unquote(Macro.escape(value)),
            "name" => unquote(Macro.escape(value))
          })
        ]

        server = start_users()

        assert Users.names("u1", server: server, command_fun: always({:ok, users})) ==
                 {:ok, %{username: nil, name: nil}}
      end
    end

    test "missing keys read as nil" do
      users = [%{"id" => "u1"}]
      server = start_users()

      assert Users.names("u1", server: server, command_fun: always({:ok, users})) ==
               {:ok, %{username: nil, name: nil}}
    end

    test "an id absent from the list is nil names, not an error" do
      users = [user(%{"id" => "someone-else"})]
      server = start_users()

      assert Users.names("nobody", server: server, command_fun: always({:ok, users})) ==
               {:ok, %{username: nil, name: nil}}
    end

    test "a command error propagates as {:error, reason}" do
      server = start_users()

      assert Users.names("u1", server: server, command_fun: always({:error, :not_connected})) ==
               {:error, :not_connected}
    end

    test "shares admin?/2's cached fetch — both answers cost one command" do
      users = [user(%{"id" => "u1", "is_owner" => true, "username" => "ben", "name" => "Ben"})]
      server = start_users()
      command_fun = scripted([{:ok, users}])

      assert Users.admin?("u1", server: server, command_fun: command_fun) == {:ok, true}

      assert Users.names("u1", server: server, command_fun: command_fun) ==
               {:ok, %{username: "ben", name: "Ben"}}

      assert call_count() == 1
    end
  end

  describe "admin?/2 failures" do
    test "a command error propagates as {:error, reason}" do
      server = start_users()

      assert Users.admin?("owner",
               server: server,
               command_fun: always({:error, :not_connected})
             ) == {:error, :not_connected}
    end

    test "a non-list success payload is an error, not a false answer" do
      server = start_users()

      assert {:error, {:unexpected_result, _}} =
               Users.admin?("owner", server: server, command_fun: always({:ok, %{"oops" => 1}}))
    end

    test "a failed fetch is not cached and does not poison the next call" do
      users = [user(%{"id" => "owner", "is_owner" => true})]
      server = start_users()
      command_fun = scripted([{:error, :timeout}, {:ok, users}])

      assert Users.admin?("owner", server: server, command_fun: command_fun) ==
               {:error, :timeout}

      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert call_count() == 2
    end

    test "a missing cache server degrades to an uncached lookup, never a crash" do
      users = [user(%{"id" => "owner", "is_owner" => true})]

      assert Users.admin?("owner",
               server: :core_users_definitely_not_running,
               command_fun: always({:ok, users})
             ) == {:ok, true}
    end
  end

  describe "caching" do
    test "two lookups inside the TTL issue only one command" do
      users = [
        user(%{"id" => "owner", "is_owner" => true}),
        user(%{"id" => "plain"})
      ]

      server = start_users()
      command_fun = scripted([{:ok, users}])

      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert call_count() == 1
    end

    test "a cached list answers for every id in it, including non-admins and absentees" do
      users = [user(%{"id" => "owner", "is_owner" => true}), user(%{"id" => "plain"})]
      server = start_users()
      command_fun = scripted([{:ok, users}])

      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert Users.admin?("plain", server: server, command_fun: command_fun) == {:ok, false}
      assert Users.admin?("ghost", server: server, command_fun: command_fun) == {:ok, false}
      assert call_count() == 1
    end

    test "an expired entry is re-fetched" do
      first = [user(%{"id" => "owner"})]
      second = [user(%{"id" => "owner", "is_owner" => true})]
      server = start_users(ttl_ms: 0)
      command_fun = scripted([{:ok, first}, {:ok, second}])

      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, false}
      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert call_count() == 2
    end

    test "invalidate/1 forces the next lookup to re-fetch" do
      users = [user(%{"id" => "owner", "is_owner" => true})]
      server = start_users()
      command_fun = scripted([{:ok, users}, {:ok, users}])

      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert Users.invalidate(server) == :ok
      assert Users.admin?("owner", server: server, command_fun: command_fun) == {:ok, true}
      assert call_count() == 2
    end
  end

  describe "default command function" do
    test "with no injected fun it goes to the WS manager and errors cleanly" do
      # The suite's EventPusher never authenticates (test.exs isolates the
      # core token path), so this exercises the real default seam right up
      # to the point where a live socket would be needed.
      server = start_users()

      assert {:error, _reason} = Users.admin?("owner", server: server)
    end
  end
end
