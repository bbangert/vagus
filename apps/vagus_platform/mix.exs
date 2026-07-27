defmodule VagusPlatform.MixProject do
  use Mix.Project

  @app :vagus_platform
  @version "0.1.0"
  @all_targets [:rpi3_64, :dragon_q6a]

  def project do
    [
      app: @app,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.16"],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  #
  # No `mod:` here — this app carries release/target machinery only. Its
  # supervision tree lives entirely in `:vagus` (`Vagus.Application`),
  # started automatically as a normal application dependency (see `deps/0`
  # below) once the release boots; a `VagusPlatform.Application` with no
  # children of its own would just be indirection.
  def application do
    [
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # The engine-supervision app, and (eventually) the supervisor API.
      {:vagus, in_umbrella: true},

      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Dependencies for all targets except :host
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Vagus-owned Nerves systems (nerves_system_vagus repo), consumed as
      # local path dependencies. Named `nerves_system_<target>` (not
      # `nerves_system_vagus_<target>`) — the repo follows the bare
      # `nerves_system_<target>` convention. Path deps never enter mix.lock,
      # so the two entries can't conflict; each is scoped by `targets:`, so
      # only the selected board's system is fetched/compiled.
      {:nerves_system_rpi3_64,
       path: "../../../nerves_system_vagus/rpi3_64",
       runtime: false,
       targets: :rpi3_64,
       nerves: [compile: true]},
      {:nerves_system_dragon_q6a,
       path: "../../../nerves_system_vagus/dragon_q6a",
       runtime: false,
       targets: :dragon_q6a,
       nerves: [compile: true]}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []
end
