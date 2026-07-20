defmodule Fresh.MixProject do
  use Mix.Project

  # Vendored copy of hex `fresh` 0.4.4 (MIT, https://github.com/bunopnu/fresh).
  #
  # Why vendored instead of `{:fresh, "~> 0.4.4"}` from Hex: fresh 0.4.4 (its
  # latest release, upstream unmaintained since 2024-04) declares
  # `elixirc_paths` as charlists (`~c"lib"`), which Elixir ~> 1.20's
  # `mix compile.elixir` now hard-rejects
  # (`Mix.raise(":elixirc_paths should be a list of string paths, ...")`,
  # `lib/mix/tasks/compile.elixir.ex`) — it used to silently accept
  # charlists. That's a real, unconditional compile failure, not a
  # deprecation warning, so `{:fresh, "~> 0.4.4"}` cannot build at all under
  # this project's pinned Elixir version. Only `elixirc_paths/1` below is
  # changed from upstream (charlists -> strings); `lib/` is byte-identical
  # to the 0.4.4 tarball. The dev/test-only deps (ex_doc, dialyxir, credo,
  # plug/bandit/websock_adapter/excoveralls for fresh's own test suite) are
  # dropped since we don't build fresh's tests here — matches what Hex's
  # published package metadata already resolves to for consumers.
  #
  # TODO: revisit once upstream either fixes this or is replaced.

  @description "WebSocket client for Elixir, built atop the Mint ecosystem"
  @version "0.4.4"

  @source_url "https://github.com/bunopnu/fresh"

  def project do
    [
      app: :fresh,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # Package
      description: @description,

      # Documentation
      name: "Fresh",
      source_url: @source_url,
      docs: [
        main: "readme",
        extras: [
          "CHANGELOG.md": [title: "Changelog"],
          "README.md": [title: "Introduction"],
          LICENSE: [title: "License"]
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mint, "~> 1.5"},
      {:mint_web_socket, "~> 1.0"},
      {:castore, "~> 1.0"}
    ]
  end
end
