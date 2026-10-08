defmodule VagusUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: [{:"test.mutations", &test_mutations/1}]
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Proves that the resource runtime's scenario tests can fail. Each run takes
  # one mechanism away from, or breaks one rule in, every runtime the tests
  # start (see `Vagus.Resource.Harness`) and must end in failed tests; a
  # suite that stays green without change notifications, say, is passing for
  # some other reason. `resync` is run against the tests that are about
  # resync alone: by design no other scenario depends on it.
  @mutations [
    {"deliver_events", "scenario"},
    {"resync", "scenario:resync"},
    {"ignore_dirty", "scenario"},
    {"skip_collector", "scenario"},
    {"double_step", "scenario"},
    {"stamp_current_generation", "scenario"},
    {"repeat_action", "scenario"}
  ]

  defp test_mutations(_args) do
    # Unmutated first: a suite that fails by itself proves nothing below.
    case scenarios(nil, "scenario") do
      {0, _failed} ->
        :ok

      {status, failed} ->
        Mix.raise(
          "stage: no mutation. The scenario tests fail by themselves (exit #{status}):\n" <>
            names(failed)
        )
    end

    survivors =
      for {mutation, only} <- @mutations,
          {status, _failed} = scenarios(mutation, only),
          # 2 is ExUnit's "tests failed"; anything else did not run them.
          status != 2,
          do: "#{mutation} (exit #{status})"

    if survivors != [],
      do:
        Mix.raise(
          "stage: mutations. No scenario test failed under: #{Enum.join(survivors, ", ")}"
        )

    Mix.shell().info(
      "every mutation was caught: #{Enum.map_join(@mutations, ", ", &elem(&1, 0))}"
    )
  end

  defp names([]), do: "  (no failing test was named in the output)"
  defp names(failed), do: Enum.map_join(failed, "\n", &("  " <> &1))

  # The exit status, and the tests the run named as failed.
  defp scenarios(mutation, only) do
    Mix.shell().info("==> scenario tests, mutation: #{mutation || "none"}")

    # `nil` unsets it: the unmutated run must not inherit a mutation from
    # the shell this was started in.
    env = [{"MIX_ENV", "test"}, {"VAGUS_RESOURCE_MUTATION", mutation}]

    args = [
      "test",
      "apps/vagus/test/vagus/resource",
      "apps/vagus/test/vagus/app/controller",
      "--only",
      only
    ]

    {output, status} = System.cmd("mix", args, env: env, stderr_to_stdout: true)
    IO.write(output)

    failed =
      for [_all, name] <- Regex.scan(~r/^\s+\d+\) (test .+)$/m, output), uniq: true, do: name

    Mix.shell().info(
      "==> mutation #{mutation || "none"}: exit #{status}, #{length(failed)} failed"
    )

    {status, failed}
  end

  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps folder.
  #
  # `:nerves` is declared here even though only the child apps use it, because
  # nerves_bootstrap reads the requirement from the project it is *invoked*
  # in — and a firmware build runs `mix deps.get` at this root. From 1.17.0 it
  # uses that requirement to tell a Nerves 1.x project from a 2.x one, and only
  # the 1.x path appends `nerves.deps.get`, the task that downloads prebuilt
  # toolchain and system artifacts. With no `:nerves` here it classifies
  # neither, `deps.get` fetches Hex packages and no artifacts, exits 0, and
  # `mix firmware` fails a step later claiming the toolchain "needs to be
  # built". Measured on 1.17.0 against a cold clone: without this line, 0
  # artifacts; with it, the toolchain and system both resolve and `mix
  # firmware` succeeds. `runtime: false` — nothing here loads it.
  defp deps do
    [{:nerves, "~> 1.13", runtime: false}]
  end
end
