defmodule VagusUmbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
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
