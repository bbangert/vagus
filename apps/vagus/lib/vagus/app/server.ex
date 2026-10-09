defmodule Vagus.App.Server do
  @moduledoc """
  One process per installed app, registered in `Vagus.App.Directory` under
  `{:slug, slug}` so a second start for the slug fails atomically. It holds
  only its slug and answers questions by reading `Vagus.Addon.State`; it stops
  `:normal` once its entry is gone.
  """

  @behaviour :gen_statem

  alias Vagus.Addon.State

  @redacted [:token_hash, :services, :discovery]

  @spec child_spec(String.t()) :: Supervisor.child_spec()
  def child_spec(slug) do
    %{id: {__MODULE__, slug}, start: {__MODULE__, :start_link, [slug]}, restart: :transient}
  end

  @spec start_link(String.t()) :: :gen_statem.start_ret()
  def start_link(slug), do: :gen_statem.start_link(name(slug), __MODULE__, slug, [])

  defp name(slug), do: {:via, Registry, {Vagus.App.Directory, {:slug, slug}}}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(slug) do
    case State.get(slug) do
      {:ok, _entry} -> {:ok, :idle, %{slug: slug}}
      :error -> :ignore
    end
  end

  @impl :gen_statem
  def handle_event({:call, from}, :info, :idle, %{slug: slug}) do
    reply_and_stop_if_gone(from, read(slug), & &1)
  end

  def handle_event({:call, from}, :installed?, :idle, %{slug: slug}) do
    reply_and_stop_if_gone(from, read(slug), &match?({:ok, _entry}, &1))
  end

  # A typo'd question from one caller must not crash-loop every app process.
  def handle_event({:call, from}, _question, _state, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :unknown_question}}]}

  # Late replies and stray messages carry nothing this process acts on.
  def handle_event(:info, _message, _state, _data), do: :keep_state_and_data

  @impl :gen_statem
  def format_status(%{data: data} = status) when is_map(data) do
    %{status | data: Map.new(data, &redact/1)}
  end

  def format_status(status), do: status

  defp redact({key, _value}) when key in @redacted, do: {key, :redacted}
  defp redact(pair), do: pair

  defp reply_and_stop_if_gone(from, :error, answer),
    do: {:stop_and_reply, :normal, [{:reply, from, answer.(:error)}]}

  defp reply_and_stop_if_gone(from, result, answer),
    do: {:keep_state_and_data, [{:reply, from, answer.(result)}]}

  # A State restart must not crash every app process at once: that many
  # restarts would exhaust `Vagus.App.Instances` and empty the tree.
  defp read(slug) do
    State.get(slug)
  catch
    :exit, _reason -> :unavailable
  end
end
