defmodule Mix.Tasks.Vagus.Probe.Diff do
  @shortdoc "Diffs two probe captures through the volatile-field allowlist"

  @moduledoc """
  Compares a captured probe fingerprint against another capture, ignoring only
  the fields an allowlist says vary by machine.

      mix vagus.probe.diff <fixture.json> <live.json> [--volatile <allowlist.json>]

  `--volatile` defaults to `apps/vagus/test/fixtures/haos-container-fingerprint.volatile.json`.
  Both sides go through the same allowlist — one task rather than per-surface
  scripts is what keeps that true.

  Prints each divergence grouped by top-level section and exits non-zero when
  there is any, so it can gate a capture as well as be read by hand.
  """

  use Mix.Task

  alias Vagus.ProbeParity.Canon

  @default_allowlist "test/fixtures/haos-container-fingerprint.volatile.json"

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [volatile: :string])

    {left, right} = files!(args)

    # Canon lives in :vagus, so the app has to be compiled and configured before
    # it can be called; nothing here needs the supervision tree running.
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:jason)

    allowlist = Canon.load_allowlist!(opts[:volatile] || default_allowlist())

    left
    |> read!()
    |> Canon.canonicalize(allowlist)
    |> Canon.diff(right |> read!() |> Canon.canonicalize(allowlist))
    |> report(left, right)
  end

  defp files!([left, right]), do: {left, right}

  defp files!(_args) do
    Mix.raise(
      "usage: mix vagus.probe.diff <fixture.json> <live.json> [--volatile <allowlist.json>]"
    )
  end

  defp default_allowlist do
    base =
      case Mix.Project.apps_paths() do
        %{vagus: path} -> path
        _not_umbrella_root -> File.cwd!()
      end

    Path.join(base, @default_allowlist)
  end

  defp read!(file) do
    case File.read(file) do
      {:ok, body} -> Jason.decode!(body)
      {:error, reason} -> Mix.raise("cannot read #{file}: #{inspect(reason)}")
    end
  end

  defp report([], _left, _right), do: Mix.shell().info("no divergences")

  defp report(divergences, left, right) do
    divergences
    |> Enum.group_by(&section/1)
    |> Enum.sort()
    |> Enum.each(fn {section, rows} ->
      Mix.shell().info("\n#{section}")
      Enum.each(rows, &Mix.shell().info(format(&1, left, right)))
    end)

    Mix.raise("#{length(divergences)} divergence(s)")
  end

  defp section(%{path: path}), do: path |> String.split("/", parts: 2) |> hd()

  defp format(divergence, left, right) do
    """
      #{divergence.path}
        #{Path.basename(left)}: #{inspect(divergence.left)}
        #{Path.basename(right)}: #{inspect(divergence.right)}\
    """
  end
end
