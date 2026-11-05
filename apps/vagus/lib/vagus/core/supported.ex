defmodule Vagus.Core.Supported do
  @moduledoc """
  The newest HA Core this Vagus release will offer or install.

  Core updates on its own cadence, and its typed Supervisor client can start
  requiring a field or a route this release does not serve (Core 2026.11.0
  broke the Vagus panel that way). Vagus decides what "latest Core" means, so
  it neither advertises nor accepts a Core newer than the one its contract
  fixtures were validated against: `Vagus.Core.Versions` clamps
  `version_latest` to it and `Vagus.Core.Lifecycle.update/2` refuses a target
  above it. Equal, older (rollback) and the installed version stay allowed.

  ## Raising the ceiling

  1. Regenerate the fixtures against the new Core: the aiohasupervisor
     contract, `core-<tag>-hassio-views.json` and the frontend endpoints
     (each test's moduledoc has its recipe).
  2. Run the contract tests and fix whatever they find.
  3. Bump `@version` below to the new Core tag. A test pins it to the Core
     views fixture's tag, so step 1 without this step fails.
  4. Release Vagus. Boards offer the new Core once they run that release.

  `config :vagus, Vagus.Core.Supported, enforce: false` turns the clamp and
  the refusal off (a warning is logged at boot), for trying a newer Core by
  hand on a dev board.
  """

  require Logger

  @version "2026.11.0"

  # HA tags are `YYYY.M.P` with an optional `bN`/`rcN`/`.devN` suffix, which
  # Version.parse/1 rejects. Pre-release ranks follow PEP 440: dev < b < rc.
  @tag_re ~r/\A(\d+)\.(\d+)\.(\d+)(?:\.?(dev|b|rc)(\d+))?\z/
  @pre_rank %{"dev" => 0, "b" => 1, "rc" => 2}

  @doc "The Core release the pinned contract fixtures were generated from."
  @spec version() :: String.t()
  def version, do: @version

  @spec enforce?() :: boolean()
  def enforce? do
    :vagus |> Application.get_env(__MODULE__, []) |> Keyword.get(:enforce, true)
  end

  @doc "Whether `v` is above the ceiling. Anything unparsable counts as above."
  @spec newer?(term()) :: boolean()
  def newer?(v) do
    case parse(v) do
      {:ok, parsed} -> Version.compare(parsed, parse!(@version)) == :gt
      :error -> true
    end
  end

  @doc """
  The `version_latest` Vagus advertises for the raw upstream `feed`: the
  installed version once that is at or above the ceiling, else the lesser of
  `feed` and the ceiling.
  """
  @spec latest(String.t() | nil, String.t() | nil) :: String.t() | nil
  def latest(installed, feed) do
    cond do
      not enforce?() or is_nil(feed) -> feed
      is_binary(installed) and not below?(installed) -> installed
      newer?(feed) -> @version
      true -> feed
    end
  end

  @doc "Whether this release may install `target` over `installed`."
  @spec permit(String.t(), String.t() | nil) ::
          :ok | {:error, {:unsupported_core, String.t(), String.t()}}
  def permit(target, installed) do
    if enforce?() and target != installed and newer?(target),
      do: {:error, {:unsupported_core, target, @version}},
      else: :ok
  end

  @doc "Whether `feed` is being withheld from `installed`."
  @spec held?(String.t() | nil, String.t() | nil) :: boolean()
  def held?(installed, feed),
    do: is_binary(feed) and feed != installed and latest(installed, feed) != feed

  @spec warn_if_unenforced() :: :ok
  def warn_if_unenforced do
    if not enforce?() do
      Logger.warning(
        "Vagus.Core.Supported: enforce is off; Core newer than #{@version} " <>
          "will be offered and installed"
      )
    end

    :ok
  end

  defp below?(v) do
    case parse(v) do
      {:ok, parsed} -> Version.compare(parsed, parse!(@version)) == :lt
      :error -> false
    end
  end

  defp parse(v) when is_binary(v) do
    case Regex.run(@tag_re, v) do
      [_all, major, minor, patch] ->
        {:ok, %Version{major: int(major), minor: int(minor), patch: int(patch)}}

      [_all, major, minor, patch, kind, n] ->
        {:ok,
         %Version{
           major: int(major),
           minor: int(minor),
           patch: int(patch),
           pre: [Map.fetch!(@pre_rank, kind), int(n)]
         }}

      nil ->
        :error
    end
  end

  defp parse(_other), do: :error

  defp parse!(v) do
    {:ok, parsed} = parse(v)
    parsed
  end

  defp int(digits), do: String.to_integer(digits)
end
