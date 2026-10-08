defmodule Vagus.App.Boot do
  @moduledoc """
  What a reboot does to whether apps run: once per boot, in one commit, an
  app that is started by hand (`boot` `:manual`) or runs once is set not to
  run, and one that always runs (`:always`) is set to. An app with `boot`
  `:auto` runs if it ran before.

  ## Once per boot

  A boot is told from a restart of the application by a marker file beside
  the run directory (`config :vagus, :run_state_dir`), which is on a tmpfs:
  gone after a reboot, there after anything less. The directory itself is
  emptied at every application start, which is why the marker is not in it.
  With no run directory configured nothing says which of the two this is,
  and it is taken for a boot.

  The marker is written twice. First with every app's uid and generation,
  then the commit is made, then the marker says done. The commit touches
  only an app that still has the uid and generation the marker recorded, so
  wherever this is cut, running it again finishes it and changes nothing
  else:

    * before the first write: nothing has happened, and the next start is
      the first;
    * between that write and the commit: the next start makes the commit,
      for the apps nobody has written to since;
    * after the commit: the apps it changed have a newer generation and are
      left alone, as is any app a user has written to in the meantime.

  What is not covered is a marker that cannot be written at all. Then the
  commit is made at every start of the application for the rest of the
  boot, and an app started by hand is stopped by the next such restart. A
  marker that cannot be read is taken for done: unreadable says a start got
  as far as writing it.

  ## Where it runs

  `child_spec/1` is a child for `Vagus.Resource.Supervisor`'s `:services`,
  after the store and before the controllers. Its start function does the
  work and answers `:ignore`: there is nothing to keep running, and a later
  child, the App runtime, must not make its first pass before the commit,
  which is the one reason to do work in a start. It runs in the supervisor,
  never in the store. A store that refuses the commit is logged and the
  start goes on: the alternative is a device on which nothing starts.
  """

  require Logger

  alias Vagus.Addon.Config
  alias Vagus.App.Profile
  alias Vagus.App.Spec.Schema
  alias Vagus.Resource
  alias Vagus.Resource.Store

  @tries 3

  @doc "Options: `:instance`, and `:marker`, a path, or `nil` for none (default `marker/0`)."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}

  @doc false
  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    normalise(opts)
    :ignore
  end

  @doc "The marker's default path, or `nil` without a run directory."
  @spec marker() :: Path.t() | nil
  def marker do
    case Application.get_env(:vagus, :run_state_dir) do
      nil -> nil
      dir -> dir <> ".booted"
    end
  end

  @doc "Whether an app with `spec` runs after a boot, or `nil` for as it was."
  @spec run_after_boot(map()) :: boolean() | nil
  def run_after_boot(spec) do
    case Profile.of(spec).boot(spec) do
      :always -> true
      :manual -> false
      :auto -> if run_once?(spec), do: false
    end
  end

  defp run_once?(%{config: %Config{startup: "once"}}), do: true
  defp run_once?(_spec), do: false

  @doc "Does it, if this boot has not. Returns whether it was this call that did."
  @spec normalise(keyword()) :: :done | :already
  def normalise(opts \\ []) do
    i = [instance: Keyword.get(opts, :instance, Resource)]
    marker = Keyword.get_lazy(opts, :marker, &marker/0)

    case read(marker) do
      :done ->
        :already

      {:pending, seen} ->
        finish(seen, marker, i)

      :none ->
        seen =
          Map.new(Store.list(Schema.kind(), i), &{&1.name, [&1.uid, &1.generation]})

        write(marker, %{"state" => "pending", "apps" => seen})
        finish(seen, marker, i)
    end
  end

  defp finish(seen, marker, i) do
    commit(seen, i, @tries)
    write(marker, %{"state" => "done"})
    :done
  end

  defp commit(seen, i, tries) do
    ops =
      for %Resource{name: name, uid: uid, generation: generation, spec: spec} = app <-
            Store.list(Schema.kind(), i),
          seen[name] == [uid, generation],
          not app.deleting?,
          run <- [run_after_boot(spec)],
          run != nil and run != spec.run,
          op <- [
            {:expect, Schema.kind(), name, uid: uid, generation: generation},
            {:update_spec, Schema.kind(), name, %{run: run}, []}
          ],
          do: op

    case ops == [] or Store.commit(ops, i) do
      true ->
        :ok

      {:ok, _apps} ->
        :ok

      # Somebody wrote to one of them between the read and the commit: that
      # app is theirs now, and the rest are tried again.
      {:error, {:precondition, _key, _field}} when tries > 1 ->
        commit(seen, i, tries - 1)

      {:error, reason} ->
        Logger.error("apps were not set for this boot: #{inspect(reason)}")
    end
  end

  defp read(nil), do: :none

  # The path is configuration, and what is read is only compared.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(marker) do
    with {:ok, json} <- File.read(marker),
         {:ok, %{"state" => "pending", "apps" => %{} = seen}} <- Jason.decode(json) do
      {:pending, seen}
    else
      {:error, :enoent} -> :none
      _done_or_unreadable -> :done
    end
  end

  defp write(nil, _content), do: :ok

  # Renamed into place: a marker half written would read as done.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(marker, content) do
    tmp = marker <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(marker)),
         :ok <- File.write(tmp, Jason.encode!(content)),
         :ok <- File.rename(tmp, marker) do
      :ok
    else
      {:error, reason} ->
        Logger.error("boot marker #{marker} was not written: #{inspect(reason)}")
    end
  end
end
