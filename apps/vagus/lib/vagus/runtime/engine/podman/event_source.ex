defmodule Vagus.Runtime.Engine.Podman.EventSource do
  @moduledoc """
  Placeholder `Vagus.Runtime.Events.Source` for podman: it never connects,
  so Events keeps retrying with backoff. Part 2 of the podman adapter
  replaces it with a tail of podman's events file.
  """

  @behaviour Vagus.Runtime.Events.Source

  @impl true
  def init(_opts), do: nil

  @impl true
  def connect(_src), do: {:error, :not_implemented}

  @impl true
  def handle_info(_msg, _src), do: :unknown

  @impl true
  def close(src), do: src
end
