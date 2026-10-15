defmodule Vagus.Runtime.Engine.Fake.EventSource do
  @moduledoc false
  # A stream that connects and never says anything, so Events runs under
  # `engine: Engine.Fake` without its own `:source`.
  @behaviour Vagus.Runtime.Events.Source

  @impl true
  def init(_opts), do: nil

  @impl true
  def connect(src), do: {:ok, [], src}

  @impl true
  def handle_info(_msg, _src), do: :unknown

  @impl true
  def close(src), do: src
end
