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
  defp deps do
    []
  end
end
