defmodule Vagus.Resource.Clock do
  @moduledoc """
  Where `Vagus.Resource.Stamp`s come from. A clock is a module implementing
  this behaviour, or a zero-arity function so a test can hold its own.
  """

  alias Vagus.Resource.Stamp

  @type t :: module() | (-> Stamp.t())

  @callback now() :: Stamp.t()

  @spec now(t()) :: Stamp.t()
  def now(clock \\ __MODULE__.System)
  def now(clock) when is_atom(clock), do: clock.now()
  def now(clock) when is_function(clock, 0), do: clock.()
end

defmodule Vagus.Resource.Clock.System do
  @moduledoc """
  Monotonic milliseconds, tagged with an incarnation that is fixed for the
  life of the VM and differs after a reboot.
  """

  @behaviour Vagus.Resource.Clock

  alias Vagus.Resource.Stamp

  @key {__MODULE__, :incarnation}

  @doc false
  # Called from `Vagus.Application.start/2`: one process, before any reader,
  # so two first readers cannot each mint an incarnation. An existing value is
  # kept because monotonic time stays comparable across a `:vagus` restart.
  # Random rather than a counter or a boot time: nothing on the board is
  # guaranteed to differ between two boots. 48 bits stays exact in any JSON
  # reader.
  @spec ensure_incarnation() :: :ok
  def ensure_incarnation do
    if :persistent_term.get(@key, nil) == nil do
      <<incarnation::48>> = :crypto.strong_rand_bytes(6)
      :persistent_term.put(@key, incarnation)
    end

    :ok
  end

  @impl true
  def now do
    %Stamp{
      incarnation: :persistent_term.get(@key),
      at: System.monotonic_time(:millisecond)
    }
  end
end
