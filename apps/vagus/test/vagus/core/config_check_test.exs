defmodule Vagus.Core.ConfigCheckTest do
  use ExUnit.Case, async: true

  alias Vagus.Core.{ConfigCheck, Container}
  alias Vagus.Runtime.Engine.Fake

  @argv ~w(python3 -m homeassistant -c /config --script check_config)

  defp engine(state, exec \\ nil) do
    fake = Fake.start()
    if state, do: Fake.put_container(fake, Container.name(), state: state, exec: exec)
    {fake, [engine: Fake, fake: fake]}
  end

  describe "Core not running" do
    test "no container at all -> {:not_running, message}" do
      {fake, opts} = engine(nil)

      assert {:not_running, message} = ConfigCheck.check(engine_opts: opts)
      assert message =~ "not running"
      assert [{:inspect, [_]}] = Fake.calls(fake)
    end

    test "container exists but stopped -> {:not_running, message}, no exec attempted" do
      for state <- [:created, :exited] do
        {fake, opts} = engine(state)

        assert {:not_running, _message} = ConfigCheck.check(engine_opts: opts)
        assert [{:inspect, [_]}] = Fake.calls(fake)
      end
    end

    test "a genuine inspect failure surfaces as {:error, reason}" do
      {fake, opts} = engine(:running)
      Fake.fail_next(fake, :inspect, {:failed, :inspect, "daemon exploded"})

      assert ConfigCheck.check(engine_opts: opts) ==
               {:error, {:failed, :inspect, "daemon exploded"}}
    end
  end

  describe "Core live — check_config exec" do
    # Live, so not `:not_running`; the engine then refuses the exec itself.
    test "paused or restarting is live: the exec is attempted and its refusal surfaces" do
      for state <- [:paused, :restarting] do
        {fake, opts} = engine(state, {0, "Success!\n"})
        assert {:error, {:failed, :exec, _}} = ConfigCheck.check(engine_opts: opts)
        assert {:exec, [_, @argv]} = List.last(Fake.calls(fake))
      end
    end

    test "a check that outlasts its deadline is {:error, :timeout}" do
      {fake, opts} = engine(:running, {0, "Success!\n"})
      Fake.delay_next(fake, :exec, 1_000)

      assert ConfigCheck.check(engine_opts: [timeout_ms: 500] ++ opts) == {:error, :timeout}
    end

    test "exit 0, clean log -> :valid, check_config exec'd as a direct argv" do
      {fake, opts} = engine(:running, {0, "Testing configuration at /config\nSuccess!\n"})

      assert :valid = ConfigCheck.check(engine_opts: opts)
      assert [{:inspect, [name]}, {:exec, [name, @argv]}] = Fake.calls(fake)
      assert name == Container.name()
    end

    test "nonzero exit -> {:invalid, log}, log is the ANSI-stripped output" do
      colored = "\e[31mFailed config\e[0m\nsome.yaml: invalid key 'foo'\n"
      {_fake, opts} = engine(:running, {1, colored})

      assert ConfigCheck.check(engine_opts: opts) ==
               {:invalid, "Failed config\nsome.yaml: invalid key 'foo'\n"}
    end

    test "exit 0 but the log carries the yaml-error marker -> {:invalid, log} (two-way fix)" do
      # Upstream's own check occasionally exits 0 even when the parser
      # logged a yaml error — the log match is what actually decides.
      output = "homeassistant.util.yaml.loader: while parsing a block mapping\n"
      {_fake, opts} = engine(:running, {0, output})

      assert {:invalid, log} = ConfigCheck.check(engine_opts: opts)
      assert log =~ "homeassistant.util.yaml"
    end

    test "an exec failure surfaces as {:error, reason}" do
      {fake, opts} = engine(:running)
      Fake.fail_next(fake, :exec, {:failed, :exec, "no such container"})

      assert ConfigCheck.check(engine_opts: opts) ==
               {:error, {:failed, :exec, "no such container"}}
    end
  end
end
