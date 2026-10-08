defmodule Vagus.App.TokenTest do
  use ExUnit.Case, async: true

  alias Vagus.App.{AuthIndex, Token}
  alias Vagus.Resource.TestInstance

  test "a minted token is 256 random bits in URL-safe characters, new each time" do
    tokens = for _ <- 1..200, do: Token.mint()
    assert length(Enum.uniq(tokens)) == 200

    for token <- tokens do
      assert token =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert byte_size(Base.url_decode64!(token, padding: false)) == 32
    end
  end

  describe "of/2" do
    test "a minted token is read from the instance's environment" do
      assert Token.of(:minted, %{"SUPERVISOR_TOKEN" => "abc", "HASSIO_TOKEN" => "other"}) == "abc"
      assert Token.of(:minted, %{"HASSIO_TOKEN" => "other"}) == nil
      assert Token.of(:minted, %{"SUPERVISOR_TOKEN" => ""}) == nil
    end

    test "the Supervisor's is read through the function given, whatever the environment says" do
      source = {:supervisor, fn -> "the-supervisor-token" end}
      assert Token.of(source, %{"SUPERVISOR_TOKEN" => "stale"}) == "the-supervisor-token"
      assert Token.of({:supervisor, fn -> nil end}, %{"SUPERVISOR_TOKEN" => "stale"}) == nil
    end

    test "a profile without a token has none" do
      assert Token.of(:none, %{"SUPERVISOR_TOKEN" => "abc"}) == nil
    end
  end

  describe "state/4" do
    setup do
      instance = TestInstance.name()
      TestInstance.start!(instance: instance, services: [{AuthIndex, instance: instance}])
      %{i: [instance: instance]}
    end

    test "says what the table holds for the app, against the token given", %{i: i} do
      assert Token.state(:minted, "app", "t1", i) == :absent
      :ok = AuthIndex.put("app", "t1", i)
      assert Token.state(:minted, "app", "t1", i) == :current
      assert Token.state(:minted, "app", "t2", i) == :other
      assert Token.state(:minted, "app", nil, i) == :other
      assert Token.state(:minted, "another", "t1", i) == :absent
      :ok = AuthIndex.remove("app", i)
      assert Token.state(:minted, "app", "t1", i) == :absent
    end

    test "a profile without a token is asked nothing", %{i: i} do
      :ok = AuthIndex.put("app", "t1", i)
      assert Token.state(:none, "app", "t1", i) == :none
    end

    test "with no table nothing is held" do
      assert Token.state(:minted, "app", "t1", instance: NoSuchInstance) == :absent
    end

    test "digest_of/2 is the digest the table holds, and nothing more", %{i: i} do
      assert AuthIndex.digest_of("app", i) == :error
      :ok = AuthIndex.put("app", "t1", i)
      assert AuthIndex.digest_of("app", i) == {:ok, :crypto.hash(:sha256, "t1")}
      :ok = AuthIndex.put("app", "t2", i)
      assert AuthIndex.digest_of("app", i) == {:ok, :crypto.hash(:sha256, "t2")}
      assert AuthIndex.digest_of("app", instance: NoSuchInstance) == :error
    end
  end

  describe "guard/1" do
    test "passes on what the function returns" do
      assert Token.guard(fn -> :ok end) == :ok
      assert Token.guard(fn -> {:error, :already_exists} end) == {:error, :already_exists}
    end

    test "what is raised, thrown or exited with leaves only its kind behind" do
      secret = "s3cret-token"
      takes_none = fn :never -> :ok end

      for failing <- [
            fn -> raise ArgumentError, "bad config #{secret}" end,
            fn -> takes_none.(secret) end,
            fn -> throw({:config, secret}) end,
            fn -> exit({:crashed_with, secret}) end,
            fn -> Map.fetch!(%{token: secret}, :missing) end
          ] do
        assert {:error, {:crashed, kind}} = Token.guard(failing)
        assert is_atom(kind)
        refute inspect(Token.guard(failing)) =~ secret
      end

      assert Token.guard(fn -> raise KeyError, key: secret end) == {:error, {:crashed, KeyError}}
      assert Token.guard(fn -> exit(secret) end) == {:error, {:crashed, :exit}}
    end

    test "an exit that says the process asked was away or slow is told apart, and is no crash" do
      secret = "s3cret-token"
      call = {GenServer, :call, [:somebody, {:put, secret}, 5_000]}

      for {reason, why} <- [
            {{:timeout, call}, :timeout},
            {{:noproc, call}, :noproc},
            {{:normal, call}, :normal},
            {{:shutdown, call}, :shutdown},
            {{{:shutdown, secret}, call}, :shutdown},
            {{:killed, call}, :killed},
            {:shutdown, :shutdown},
            {{:shutdown, secret}, :shutdown},
            {:noproc, :noproc}
          ] do
        assert Token.guard(fn -> exit(reason) end) == {:error, {:exit, why}}
      end

      # As a call to a name nobody has really exits.
      nobody = Module.concat(__MODULE__, "Nobody#{System.unique_integer([:positive])}")

      assert Token.guard(fn -> GenServer.call(nobody, :anything) end) ==
               {:error, {:exit, :noproc}}

      # The process asked having crashed over the request is a crash.
      crashed = {{%RuntimeError{message: secret}, []}, call}
      assert Token.guard(fn -> exit(crashed) end) == {:error, {:crashed, :exit}}

      assert Token.guard(fn -> exit({:timeout_of_another_kind, secret}) end) ==
               {:error, {:crashed, :exit}}
    end
  end
end
